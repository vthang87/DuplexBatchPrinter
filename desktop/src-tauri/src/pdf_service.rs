use std::collections::BTreeMap;
use std::fs;
use std::io::BufWriter;
use std::path::{Path, PathBuf};

use image::GenericImageView;
use lopdf::{dictionary, Dictionary, Document, Object, ObjectId, Stream};
use printpdf::{
    Color, ImageTransform, Mm, PdfDocument, PdfLayerReference, Point, Polygon, Rgb,
};
use thiserror::Error;
use uuid::Uuid;

use crate::models::{Localized, PaperRotation, PaperSize, PlannedPage};

#[derive(Debug, Error)]
pub enum PdfServiceError {
    #[error("Cannot open {0}")]
    CannotOpen(String),
    #[error("Cannot open image {0}")]
    CannotOpenImage(String),
    #[error("Add at least one image before printing.")]
    EmptyImageList,
    #[error("{0} has no pages.")]
    EmptyDocument(String),
    #[error("Cannot create a blank PDF page.")]
    CannotCreatePage,
    #[error("Cannot write temporary PDF at {0}")]
    CannotWrite(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Lopdf(#[from] lopdf::Error),
}

impl PdfServiceError {
    pub fn localized(&self) -> Localized {
        match self {
            Self::CannotOpen(name) => Localized::new("error.pdf.cannotOpen").with("name", name),
            Self::CannotOpenImage(name) => {
                Localized::new("error.pdf.cannotOpenImage").with("name", name)
            }
            Self::EmptyImageList => Localized::new("error.pdf.emptyImageList"),
            Self::EmptyDocument(name) => {
                Localized::new("error.pdf.emptyDocument").with("name", name)
            }
            Self::CannotCreatePage => Localized::new("error.pdf.cannotCreatePage"),
            Self::CannotWrite(path) => Localized::new("error.pdf.cannotWrite").with("path", path),
            Self::Io(err) => Localized::raw(err),
            Self::Lopdf(err) => Localized::raw(err),
        }
    }
}

fn display_name(path: &Path, fallback: &str) -> String {
    path.file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(fallback)
        .to_string()
}

/// Page attributes a page may inherit from its ancestors in the page tree
/// (PDF 32000-1, 7.7.3.4). They must be copied onto the page itself before
/// the page is detached from its original tree.
const INHERITABLE_KEYS: [&[u8]; 4] = [b"Resources", b"MediaBox", b"CropBox", b"Rotate"];

pub struct PdfService;

impl PdfService {
    pub fn page_count(path: &Path) -> Result<usize, PdfServiceError> {
        let doc = Document::load(path)
            .map_err(|_| PdfServiceError::CannotOpen(display_name(path, "PDF")))?;
        let count = doc.get_pages().len();
        if count == 0 {
            return Err(PdfServiceError::EmptyDocument(display_name(path, "PDF")));
        }
        Ok(count)
    }

    pub fn validate_image(path: &Path) -> Result<(), PdfServiceError> {
        let img = image::open(path)
            .map_err(|_| PdfServiceError::CannotOpenImage(display_name(path, "image")))?;
        let (w, h) = img.dimensions();
        if w == 0 || h == 0 {
            return Err(PdfServiceError::CannotOpenImage(display_name(path, "image")));
        }
        Ok(())
    }

    pub fn make_pass(
        source: &Path,
        pages: &[PlannedPage],
        rotation: PaperRotation,
        temporary_directory: &Path,
        label: &str,
    ) -> Result<PathBuf, PdfServiceError> {
        let source_doc = Document::load(source)
            .map_err(|_| PdfServiceError::CannotOpen(display_name(source, "PDF")))?;
        let source_pages = source_doc.get_pages();
        if source_pages.is_empty() {
            return Err(PdfServiceError::EmptyDocument(display_name(source, "PDF")));
        }

        let (media_w, media_h) = page_media_size(&source_doc, *source_pages.values().next().unwrap());

        let mut output = Document::with_version("1.5");
        let pages_id = output.new_object_id();
        let mut page_ids = Vec::new();

        for planned in pages {
            let page_id = if let Some(number) = planned.source_page {
                let Some((_, object_id)) = source_pages.iter().find(|(n, _)| **n == number as u32) else {
                    return Err(PdfServiceError::CannotCreatePage);
                };
                import_page(&source_doc, &mut output, *object_id, rotation)?
            } else {
                create_blank_page(&mut output, pages_id, media_w, media_h)?
            };
            if let Ok(Object::Dictionary(dict)) = output.get_object_mut(page_id) {
                dict.set("Parent", Object::Reference(pages_id));
            }
            page_ids.push(page_id.into());
        }

        finish_document(&mut output, pages_id, page_ids);
        let destination = temporary_directory.join(format!("{}-{}.pdf", Uuid::new_v4(), safe_label(label)));
        output
            .save(&destination)
            .map_err(|_| PdfServiceError::CannotWrite(destination.display().to_string()))?;
        Ok(destination)
    }

    pub fn make_merged_document(
        source_paths: &[PathBuf],
        temporary_directory: &Path,
    ) -> Result<(PathBuf, Vec<usize>), PdfServiceError> {
        let mut output = Document::with_version("1.5");
        let pages_id = output.new_object_id();
        let mut page_ids = Vec::new();
        let mut page_counts = Vec::new();

        for path in source_paths {
            let source = Document::load(path)
                .map_err(|_| PdfServiceError::CannotOpen(display_name(path, "PDF")))?;
            let source_pages = source.get_pages();
            if source_pages.is_empty() {
                return Err(PdfServiceError::EmptyDocument(display_name(path, "PDF")));
            }
            page_counts.push(source_pages.len());
            let mut ordered: Vec<_> = source_pages.into_iter().collect();
            ordered.sort_by_key(|(n, _)| *n);
            for (_, object_id) in ordered {
                let page_id = import_page(&source, &mut output, object_id, PaperRotation::None)?;
                if let Ok(Object::Dictionary(dict)) = output.get_object_mut(page_id) {
                    dict.set("Parent", Object::Reference(pages_id));
                }
                page_ids.push(page_id.into());
            }
        }

        finish_document(&mut output, pages_id, page_ids);
        let destination = temporary_directory.join(format!("{}-merged.pdf", Uuid::new_v4()));
        output
            .save(&destination)
            .map_err(|_| PdfServiceError::CannotWrite(destination.display().to_string()))?;
        Ok((destination, page_counts))
    }

    pub fn make_image_document(
        source_paths: &[PathBuf],
        paper_size: PaperSize,
        temporary_directory: &Path,
        label: &str,
    ) -> Result<PathBuf, PdfServiceError> {
        if source_paths.is_empty() {
            return Err(PdfServiceError::EmptyImageList);
        }
        let (width_pt, height_pt) = paper_size.pdf_page_size_points();
        let width_mm = Mm(width_pt * 25.4 / 72.0);
        let height_mm = Mm(height_pt * 25.4 / 72.0);

        let (doc, page1, layer1) = PdfDocument::new("Image batch", width_mm, height_mm, "Layer 1");
        let mut current_layer = doc.get_page(page1).get_layer(layer1);

        for (index, path) in source_paths.iter().enumerate() {
            if index > 0 {
                let (page, layer) = doc.add_page(width_mm, height_mm, format!("Page {}", index + 1));
                current_layer = doc.get_page(page).get_layer(layer);
            }
            place_image_on_layer(&current_layer, path, width_pt, height_pt)?;
        }

        let destination = temporary_directory.join(format!("{}-{}.pdf", Uuid::new_v4(), safe_label(label)));
        let file = fs::File::create(&destination)
            .map_err(|_| PdfServiceError::CannotWrite(destination.display().to_string()))?;
        doc.save(&mut BufWriter::new(file))
            .map_err(|_| PdfServiceError::CannotWrite(destination.display().to_string()))?;
        Ok(destination)
    }

    pub fn create_calibration_pdf(directory: &Path) -> Result<PathBuf, PdfServiceError> {
        let width_mm = Mm(210.0);
        let height_mm = Mm(297.0);
        let (doc, page1, layer1) = PdfDocument::new("Duplex Calibration", width_mm, height_mm, "Layer 1");
        let bold = doc
            .add_builtin_font(printpdf::BuiltinFont::HelveticaBold)
            .map_err(|_| PdfServiceError::CannotCreatePage)?;
        let regular = doc
            .add_builtin_font(printpdf::BuiltinFont::Helvetica)
            .map_err(|_| PdfServiceError::CannotCreatePage)?;
        let black = Color::Rgb(Rgb::new(0.0, 0.0, 0.0, None));
        let red = Color::Rgb(Rgb::new(0.86, 0.15, 0.15, None));
        let gray = Color::Rgb(Rgb::new(0.33, 0.33, 0.33, None));

        for number in 1..=4 {
            let layer = if number == 1 {
                doc.get_page(page1).get_layer(layer1)
            } else {
                let (page, layer) = doc.add_page(width_mm, height_mm, format!("Page {number}"));
                doc.get_page(page).get_layer(layer)
            };
            let title = if number % 2 == 0 {
                format!("BACK {number}")
            } else {
                format!("FRONT {number}")
            };

            layer.set_fill_color(black.clone());
            layer.use_text(&title, 52.0, Mm(53.0), Mm(145.0), &bold);

            // "TOP OF SHEET" plus an up arrow drawn as a shape: the built-in
            // PDF fonts have no arrow glyph.
            layer.set_fill_color(red.clone());
            layer.use_text("TOP OF SHEET", 22.0, Mm(67.0), Mm(272.0), &bold);
            let arrow = [
                (136.0, 271.0),
                (139.0, 271.0),
                (139.0, 276.0),
                (141.5, 276.0),
                (137.5, 281.0),
                (133.5, 276.0),
                (136.0, 276.0),
            ];
            layer.add_polygon(Polygon {
                rings: vec![arrow
                    .iter()
                    .map(|(x, y)| (Point::new(Mm(*x), Mm(*y)), false))
                    .collect()],
                mode: printpdf::path::PaintMode::Fill,
                winding_order: printpdf::path::WindingOrder::NonZero,
            });

            layer.set_fill_color(gray.clone());
            layer.use_text(
                format!("Calibration page {number} of 4"),
                16.0,
                Mm(67.0),
                Mm(21.0),
                &regular,
            );
        }

        let destination = directory.join("Duplex-Calibration.pdf");
        let file = fs::File::create(&destination)
            .map_err(|_| PdfServiceError::CannotWrite(destination.display().to_string()))?;
        doc.save(&mut BufWriter::new(file))
            .map_err(|_| PdfServiceError::CannotWrite(destination.display().to_string()))?;
        Ok(destination)
    }
}

fn safe_label(label: &str) -> String {
    label
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect()
}

fn finish_document(output: &mut Document, pages_id: ObjectId, page_ids: Vec<Object>) {
    let count = page_ids.len() as i64;
    output.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages",
            "Count" => count,
            "Kids" => page_ids,
        }),
    );
    let catalog_id = output.add_object(dictionary! {
        "Type" => "Catalog",
        "Pages" => pages_id,
    });
    output.trailer.set("Root", catalog_id);
}

fn place_image_on_layer(
    layer: &PdfLayerReference,
    path: &Path,
    page_w: f32,
    page_h: f32,
) -> Result<(), PdfServiceError> {
    let img = image::open(path)
        .map_err(|_| PdfServiceError::CannotOpenImage(display_name(path, "image")))?;
    let rgba = img.to_rgba8();
    let (img_w, img_h) = rgba.dimensions();
    let (x, y, scale) = fit_image(img_w, img_h, page_w, page_h);

    let dynamic = image::DynamicImage::ImageRgba8(rgba);
    let pdf_image = printpdf::Image::from_dynamic_image(&dynamic);
    pdf_image.add_to_layer(
        layer.clone(),
        ImageTransform {
            translate_x: Some(Mm(x * 25.4 / 72.0)),
            translate_y: Some(Mm(y * 25.4 / 72.0)),
            scale_x: Some(scale),
            scale_y: Some(scale),
            // printpdf sizes images at 300 dpi by default. At 72 dpi one pixel
            // is one point, so `scale` (points per pixel) is applied as is.
            dpi: Some(72.0),
            ..Default::default()
        },
    );
    Ok(())
}

/// Fits an image into the page with an 18 pt margin, centred, keeping its
/// aspect ratio. Returns the lower-left corner and points-per-pixel scale.
fn fit_image(img_w: u32, img_h: u32, page_w: f32, page_h: f32) -> (f32, f32, f32) {
    let margin = 18.0_f32;
    let available_w = page_w - margin * 2.0;
    let available_h = page_h - margin * 2.0;
    let scale = (available_w / img_w as f32).min(available_h / img_h as f32);
    let fitted_w = img_w as f32 * scale;
    let fitted_h = img_h as f32 * scale;
    ((page_w - fitted_w) / 2.0, (page_h - fitted_h) / 2.0, scale)
}

/// Looks up `key` on the page or, failing that, on its nearest ancestor.
fn inherited_attribute(doc: &Document, page_id: ObjectId, key: &[u8]) -> Option<Object> {
    let mut current = doc.get_dictionary(page_id).ok()?;
    for _ in 0..64 {
        if let Ok(value) = current.get(key) {
            return Some(value.clone());
        }
        let parent = current.get(b"Parent").ok()?.as_reference().ok()?;
        current = doc.get_dictionary(parent).ok()?;
    }
    None
}

fn page_media_size(doc: &Document, page_id: ObjectId) -> (f32, f32) {
    let rect = inherited_attribute(doc, page_id, b"MediaBox").and_then(|obj| rect_of(doc, &obj));
    match rect {
        Some([x1, y1, x2, y2]) => ((x2 - x1).abs(), (y2 - y1).abs()),
        None => (595.0, 842.0),
    }
}

fn rect_of(doc: &Document, obj: &Object) -> Option<[f32; 4]> {
    let (_, resolved) = doc.dereference(obj).ok()?;
    let Object::Array(items) = resolved else { return None };
    if items.len() < 4 {
        return None;
    }
    let mut values = [0.0_f32; 4];
    for (slot, item) in values.iter_mut().zip(items.iter()) {
        *slot = doc.dereference(item).ok()?.1.as_float().ok()?;
    }
    Some(values)
}

fn create_blank_page(
    output: &mut Document,
    parent: ObjectId,
    width: f32,
    height: f32,
) -> Result<ObjectId, PdfServiceError> {
    // Near-white 1pt marker keeps CUPS from dropping intentional padding pages.
    let content = "q\n0.99 0.99 0.99 rg\n4 4 1 1 re\nf\nQ\n".to_string();
    let content_id = output.add_object(Stream::new(dictionary! {}, content.into_bytes()));
    let page_id = output.add_object(dictionary! {
        "Type" => "Page",
        "Parent" => parent,
        "MediaBox" => vec![0.into(), 0.into(), width.into(), height.into()],
        "Contents" => content_id,
        "Resources" => dictionary! {},
    });
    Ok(page_id)
}

fn import_page(
    source: &Document,
    output: &mut Document,
    page_id: ObjectId,
    rotation: PaperRotation,
) -> Result<ObjectId, PdfServiceError> {
    let mut page = source
        .get_dictionary(page_id)
        .map_err(|_| PdfServiceError::CannotCreatePage)?
        .clone();
    for key in INHERITABLE_KEYS {
        if page.get(key).is_err() {
            if let Some(value) = inherited_attribute(source, page_id, key) {
                page.set(key.to_vec(), value);
            }
        }
    }

    // Map the source page id up front so annotation /P back-references point
    // at the copy instead of pulling in a second copy of the page.
    let mut id_map: BTreeMap<ObjectId, ObjectId> = BTreeMap::new();
    let new_page_id = output.new_object_id();
    id_map.insert(page_id, new_page_id);
    let rewritten = rewrite_object(source, output, Object::Dictionary(page), &mut id_map)?;
    output.objects.insert(new_page_id, rewritten);

    flatten_annotations(output, new_page_id)?;

    if rotation == PaperRotation::Rotate180 {
        if let Ok(Object::Dictionary(dict)) = output.get_object_mut(new_page_id) {
            let current = dict
                .get(b"Rotate")
                .ok()
                .and_then(|obj| obj.as_float().ok())
                .map(|v| v as i64)
                .unwrap_or(0);
            dict.set("Rotate", Object::Integer((current + 180).rem_euclid(360)));
        }
    }
    Ok(new_page_id)
}

/// Annotation flags (PDF 32000-1, 12.5.3).
const ANNOT_HIDDEN: i64 = 1 << 1;
const ANNOT_NO_VIEW: i64 = 1 << 5;

/// Draws every visible annotation appearance into the page content and drops
/// those annotations, like the Swift app's flattening. Some printer drivers
/// skip the annotation layer even when its Print flag is set, which makes a
/// marked-up sheet print like its blank original.
fn flatten_annotations(doc: &mut Document, page_id: ObjectId) -> Result<(), PdfServiceError> {
    let page = doc
        .get_dictionary(page_id)
        .map_err(|_| PdfServiceError::CannotCreatePage)?
        .clone();
    let Ok(annots_obj) = page.get(b"Annots") else { return Ok(()) };
    let annots = match doc.dereference(annots_obj) {
        Ok((_, Object::Array(items))) => items.clone(),
        _ => return Ok(()),
    };

    let mut kept = Vec::new();
    let mut draws = String::new();
    let mut xobjects: Vec<(String, ObjectId)> = Vec::new();

    for annot_ref in annots {
        let Some(placement) = appearance_placement(doc, &annot_ref) else {
            kept.push(annot_ref);
            continue;
        };
        match placement {
            Placement::Skip => {}
            Placement::Draw { stream_id, matrix } => {
                let name = format!("FlatAnnot{}", xobjects.len());
                if let Ok(Object::Stream(stream)) = doc.get_object_mut(stream_id) {
                    stream.dict.set("Type", Object::Name(b"XObject".to_vec()));
                    stream.dict.set("Subtype", Object::Name(b"Form".to_vec()));
                }
                let [a, b, c, d, e, f] = matrix;
                draws.push_str(&format!(
                    "q {a:.6} {b:.6} {c:.6} {d:.6} {e:.6} {f:.6} cm /{name} Do Q\n"
                ));
                xobjects.push((name, stream_id));
            }
        }
    }

    if xobjects.is_empty() && kept.len() == annots_len(doc, &page) {
        return Ok(());
    }

    // Resources: resolve to an inline dictionary so adding XObjects never
    // touches an object another page might share.
    let mut resources = page
        .get(b"Resources")
        .ok()
        .and_then(|obj| doc.dereference(obj).ok())
        .and_then(|(_, obj)| obj.as_dict().ok().cloned())
        .unwrap_or_default();
    let mut xobject_dict = resources
        .get(b"XObject")
        .ok()
        .and_then(|obj| doc.dereference(obj).ok())
        .and_then(|(_, obj)| obj.as_dict().ok().cloned())
        .unwrap_or_default();
    for (name, id) in &xobjects {
        xobject_dict.set(name.as_bytes().to_vec(), Object::Reference(*id));
    }
    resources.set("XObject", Object::Dictionary(xobject_dict));

    // Contents: isolate the original graphics state, then draw annotations.
    let mut contents: Vec<Object> = match page.get(b"Contents") {
        Ok(obj @ Object::Reference(_)) => match doc.dereference(obj) {
            Ok((_, Object::Array(items))) => items.clone(),
            _ => vec![obj.clone()],
        },
        Ok(Object::Array(items)) => items.clone(),
        _ => Vec::new(),
    };
    let open_id = doc.add_object(Stream::new(dictionary! {}, b"q\n".to_vec()));
    let close_id = doc.add_object(Stream::new(dictionary! {}, format!("Q\n{draws}").into_bytes()));
    contents.insert(0, Object::Reference(open_id));
    contents.push(Object::Reference(close_id));

    if let Ok(Object::Dictionary(dict)) = doc.get_object_mut(page_id) {
        dict.set("Resources", Object::Dictionary(resources));
        dict.set("Contents", Object::Array(contents));
        if kept.is_empty() {
            dict.remove(b"Annots");
        } else {
            dict.set("Annots", Object::Array(kept));
        }
    }
    Ok(())
}

fn annots_len(doc: &Document, page: &Dictionary) -> usize {
    page.get(b"Annots")
        .ok()
        .and_then(|obj| doc.dereference(obj).ok())
        .and_then(|(_, obj)| obj.as_array().ok().map(|a| a.len()))
        .unwrap_or(0)
}

enum Placement {
    /// Hidden annotation: drop it, draw nothing.
    Skip,
    Draw { stream_id: ObjectId, matrix: [f32; 6] },
}

/// Returns `None` when the annotation has no appearance to draw (it is kept).
fn appearance_placement(doc: &mut Document, annot_ref: &Object) -> Option<Placement> {
    let annot = doc.dereference(annot_ref).ok()?.1.as_dict().ok()?.clone();
    let flags = annot
        .get(b"F")
        .ok()
        .and_then(|f| f.as_i64().ok())
        .unwrap_or(0);
    if flags & (ANNOT_HIDDEN | ANNOT_NO_VIEW) != 0 {
        return Some(Placement::Skip);
    }

    let ap = doc.dereference(annot.get(b"AP").ok()?).ok()?.1.as_dict().ok()?.clone();
    let normal = ap.get(b"N").ok()?;
    let mut stream_obj = normal.clone();
    // A dictionary of states (checkboxes, radio buttons): pick /AS.
    if let Ok((_, Object::Dictionary(states))) = doc.dereference(normal) {
        let state = annot.get(b"AS").ok()?;
        let Object::Name(state) = state else { return None };
        stream_obj = states.get(state).ok()?.clone();
    }
    let stream_id = match stream_obj {
        Object::Reference(id) => id,
        Object::Stream(stream) => doc.add_object(stream),
        _ => return None,
    };
    let Ok(Object::Stream(stream)) = doc.get_object(stream_id) else { return None };

    let rect = rect_of(doc, annot.get(b"Rect").ok()?)?;
    let bbox = rect_of(doc, stream.dict.get(b"BBox").ok()?)?;
    let form_matrix = stream
        .dict
        .get(b"Matrix")
        .ok()
        .and_then(|m| match doc.dereference(m).ok()?.1 {
            Object::Array(items) if items.len() == 6 => {
                let mut values = [0.0_f32; 6];
                for (slot, item) in values.iter_mut().zip(items.iter()) {
                    *slot = item.as_float().ok()?;
                }
                Some(values)
            }
            _ => None,
        })
        .unwrap_or([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);

    let matrix = appearance_matrix(rect, bbox, form_matrix)?;
    Some(Placement::Draw { stream_id, matrix })
}

/// The matrix A of PDF 32000-1, 12.5.5: maps the form's transformed bounding
/// box onto the annotation rectangle.
fn appearance_matrix(rect: [f32; 4], bbox: [f32; 4], m: [f32; 6]) -> Option<[f32; 6]> {
    let corners = [
        (bbox[0], bbox[1]),
        (bbox[2], bbox[1]),
        (bbox[0], bbox[3]),
        (bbox[2], bbox[3]),
    ];
    let transformed: Vec<(f32, f32)> = corners
        .iter()
        .map(|(x, y)| (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]))
        .collect();
    let min_x = transformed.iter().map(|p| p.0).fold(f32::INFINITY, f32::min);
    let max_x = transformed.iter().map(|p| p.0).fold(f32::NEG_INFINITY, f32::max);
    let min_y = transformed.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
    let max_y = transformed.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max);
    let box_w = max_x - min_x;
    let box_h = max_y - min_y;
    if box_w.abs() < f32::EPSILON || box_h.abs() < f32::EPSILON {
        return None;
    }
    let (rx1, rx2) = (rect[0].min(rect[2]), rect[0].max(rect[2]));
    let (ry1, ry2) = (rect[1].min(rect[3]), rect[1].max(rect[3]));
    let sx = (rx2 - rx1) / box_w;
    let sy = (ry2 - ry1) / box_h;
    Some([sx, 0.0, 0.0, sy, rx1 - min_x * sx, ry1 - min_y * sy])
}

fn copy_object_deep(
    source: &Document,
    output: &mut Document,
    object_id: ObjectId,
    id_map: &mut BTreeMap<ObjectId, ObjectId>,
) -> Result<ObjectId, PdfServiceError> {
    if let Some(existing) = id_map.get(&object_id) {
        return Ok(*existing);
    }
    let object = source
        .get_object(object_id)
        .map_err(|_| PdfServiceError::CannotCreatePage)?
        .clone();
    let new_id = output.new_object_id();
    id_map.insert(object_id, new_id);
    let rewritten = rewrite_object(source, output, object, id_map)?;
    output.objects.insert(new_id, rewritten);
    Ok(new_id)
}

fn rewrite_object(
    source: &Document,
    output: &mut Document,
    object: Object,
    id_map: &mut BTreeMap<ObjectId, ObjectId>,
) -> Result<Object, PdfServiceError> {
    match object {
        Object::Reference(id) => {
            let copied = copy_object_deep(source, output, id, id_map)?;
            Ok(Object::Reference(copied))
        }
        Object::Dictionary(dict) => {
            let mut new_dict = lopdf::Dictionary::new();
            for (key, value) in dict.into_iter() {
                // Drop Parent so the new Pages tree can own the page.
                if key == b"Parent" {
                    continue;
                }
                new_dict.set(key, rewrite_object(source, output, value, id_map)?);
            }
            Ok(Object::Dictionary(new_dict))
        }
        Object::Array(items) => {
            let mut new_items = Vec::with_capacity(items.len());
            for item in items {
                new_items.push(rewrite_object(source, output, item, id_map)?);
            }
            Ok(Object::Array(new_items))
        }
        Object::Stream(mut stream) => {
            let mut new_dict = lopdf::Dictionary::new();
            for (key, value) in stream.dict.into_iter() {
                new_dict.set(key, rewrite_object(source, output, value, id_map)?);
            }
            stream.dict = new_dict;
            Ok(Object::Stream(stream))
        }
        other => Ok(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pdfservice-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// One page whose Resources, MediaBox and Rotate live on the Pages node,
    /// carrying one visible and one hidden annotation with appearances.
    fn inherited_fixture(dir: &Path) -> PathBuf {
        let mut doc = Document::with_version("1.5");
        let pages_id = doc.new_object_id();
        let font_id = doc.add_object(dictionary! {
            "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica",
        });
        let content_id = doc.add_object(Stream::new(
            dictionary! {},
            b"BT /F1 12 Tf 72 720 Td (Hello) Tj ET".to_vec(),
        ));
        let ap_id = doc.add_object(Stream::new(
            dictionary! { "BBox" => vec![0.into(), 0.into(), 10.into(), 10.into()] },
            b"1 0 0 rg 0 0 10 10 re f".to_vec(),
        ));
        let hidden_ap_id = doc.add_object(Stream::new(
            dictionary! { "BBox" => vec![0.into(), 0.into(), 10.into(), 10.into()] },
            b"0 0 1 rg 0 0 10 10 re f".to_vec(),
        ));
        let page_id = doc.new_object_id();
        let visible = doc.add_object(dictionary! {
            "Type" => "Annot", "Subtype" => "Square", "P" => page_id,
            "Rect" => vec![100.into(), 200.into(), 120.into(), 220.into()],
            "AP" => dictionary! { "N" => ap_id },
        });
        let hidden = doc.add_object(dictionary! {
            "Type" => "Annot", "Subtype" => "Square", "F" => 2,
            "Rect" => vec![0.into(), 0.into(), 10.into(), 10.into()],
            "AP" => dictionary! { "N" => hidden_ap_id },
        });
        let link = doc.add_object(dictionary! {
            "Type" => "Annot", "Subtype" => "Link",
            "Rect" => vec![0.into(), 0.into(), 10.into(), 10.into()],
        });
        doc.objects.insert(
            page_id,
            Object::Dictionary(dictionary! {
                "Type" => "Page", "Parent" => pages_id, "Contents" => content_id,
                "Annots" => vec![visible.into(), hidden.into(), link.into()],
            }),
        );
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages", "Count" => 1, "Kids" => vec![page_id.into()],
                "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
                "Rotate" => 90,
                "Resources" => dictionary! { "Font" => dictionary! { "F1" => font_id } },
            }),
        );
        let catalog = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
        doc.trailer.set("Root", catalog);
        let path = dir.join("fixture.pdf");
        doc.save(&path).unwrap();
        path
    }

    fn only_page(path: &Path) -> (Document, Dictionary) {
        let doc = Document::load(path).unwrap();
        let id = *doc.get_pages().values().next().unwrap();
        let page = doc.get_dictionary(id).unwrap().clone();
        (doc, page)
    }

    #[test]
    fn pass_copies_inherited_page_attributes() {
        let dir = temp_dir();
        let source = inherited_fixture(&dir);
        let out = PdfService::make_pass(
            &source,
            &[PlannedPage { source_page: Some(1) }, PlannedPage { source_page: None }],
            PaperRotation::Rotate180,
            &dir,
            "t",
        )
        .unwrap();
        let (doc, page) = only_page(&out);
        let resources = doc.dereference(page.get(b"Resources").unwrap()).unwrap().1.as_dict().unwrap();
        assert!(resources.get(b"Font").is_ok(), "inherited fonts must be copied");
        assert_eq!(rect_of(&doc, page.get(b"MediaBox").unwrap()), Some([0.0, 0.0, 612.0, 792.0]));
        assert_eq!(page.get(b"Rotate").unwrap().as_i64().unwrap(), 270);

        // The blank padding page takes the inherited media size.
        let blank_id = doc.get_pages()[&2];
        let blank = doc.get_dictionary(blank_id).unwrap();
        assert_eq!(rect_of(&doc, blank.get(b"MediaBox").unwrap()), Some([0.0, 0.0, 612.0, 792.0]));
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn pass_flattens_visible_annotations_and_keeps_links() {
        let dir = temp_dir();
        let source = inherited_fixture(&dir);
        let out = PdfService::make_pass(
            &source,
            &[PlannedPage { source_page: Some(1) }],
            PaperRotation::None,
            &dir,
            "t",
        )
        .unwrap();
        let (doc, page) = only_page(&out);

        let annots = doc.dereference(page.get(b"Annots").unwrap()).unwrap().1.as_array().unwrap();
        assert_eq!(annots.len(), 1, "only the link annotation stays");

        let resources = doc.dereference(page.get(b"Resources").unwrap()).unwrap().1.as_dict().unwrap();
        let xobjects = resources.get(b"XObject").unwrap().as_dict().unwrap();
        assert_eq!(xobjects.len(), 1, "only the visible annotation is drawn");

        let content = doc.get_page_content(doc.get_pages()[&1]);
        let text = String::from_utf8_lossy(&content);
        assert!(text.starts_with("q\n"));
        assert!(text.contains("2.000000 0.000000 0.000000 2.000000 100.000000 200.000000 cm /FlatAnnot0 Do"));
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn appearance_matrix_maps_bbox_to_rect() {
        let m = appearance_matrix([10.0, 20.0, 30.0, 60.0], [0.0, 0.0, 10.0, 20.0], [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]).unwrap();
        assert_eq!(m, [2.0, 0.0, 0.0, 2.0, 10.0, 20.0]);
        assert!(appearance_matrix([0.0; 4], [0.0; 4], [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]).is_none());
    }

    #[test]
    fn image_fit_fills_page_minus_margin() {
        // A4 page, 1000x500 px landscape image: width-limited.
        let (x, y, scale) = fit_image(1000, 500, 595.0, 842.0);
        assert!((scale - 0.559).abs() < 0.001);
        assert!((x - 18.0).abs() < 0.01);
        assert!((y - (842.0 - 500.0 * scale) / 2.0).abs() < 0.01);
    }

    #[test]
    fn image_document_draws_image_at_fitted_size() {
        let dir = temp_dir();
        let img_path = dir.join("img.png");
        image::RgbaImage::from_pixel(100, 200, image::Rgba([255, 0, 0, 255]))
            .save(&img_path)
            .unwrap();
        let out = PdfService::make_image_document(&[img_path], PaperSize::A4, &dir, "img").unwrap();
        let doc = Document::load(&out).unwrap();
        let content = doc.get_page_content(doc.get_pages()[&1]);
        let text = String::from_utf8_lossy(&content);
        // Height-limited: (842 - 36) / 200 = 4.03 pt per px -> 403 x 806 pt,
        // centred at x = (595 - 403) / 2 = 96, y = 18.
        let cm: Vec<f32> = text
            .lines()
            .find(|l| l.trim_end().ends_with(" cm"))
            .expect("image placement")
            .split_whitespace()
            .take(6)
            .map(|v| v.parse().unwrap())
            .collect();
        let close = |a: f32, b: f32| (a - b).abs() < 0.5;
        assert!(close(cm[0], 403.0) && close(cm[3], 806.0), "size {cm:?}");
        assert!(close(cm[4], 96.0) && close(cm[5], 18.0), "origin {cm:?}");
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn calibration_pdf_has_four_pages() {
        let dir = temp_dir();
        let out = PdfService::create_calibration_pdf(&dir).unwrap();
        assert_eq!(PdfService::page_count(&out).unwrap(), 4);
        fs::remove_dir_all(dir).ok();
    }
}
