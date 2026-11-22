use crate::models::{DuplexPlan, PageOrder, PlannedPage, PrinterProfile};

pub struct DuplexPlanner;

impl DuplexPlanner {
    pub fn plan(page_count: usize, profile: &PrinterProfile) -> DuplexPlan {
        Self::plan_counts(&[page_count], profile)
    }

    /// Plans several documents that were merged back to back into one source PDF.
    /// Each document is padded to an even length first, so every document starts
    /// on the front of a new sheet and the printed stack separates into sets.
    pub fn plan_counts(page_counts: &[usize], profile: &PrinterProfile) -> DuplexPlan {
        let mut sequence: Vec<Option<usize>> = Vec::new();
        let mut offset = 0usize;
        for &count in page_counts {
            if count == 0 {
                continue;
            }
            for page in 1..=count {
                sequence.push(Some(offset + page));
            }
            if count % 2 != 0 {
                sequence.push(None);
            }
            offset += count;
        }

        let mut odd: Vec<PlannedPage> = sequence
            .iter()
            .step_by(2)
            .map(|page| PlannedPage {
                source_page: *page,
            })
            .collect();
        let mut even: Vec<PlannedPage> = sequence
            .iter()
            .skip(1)
            .step_by(2)
            .map(|page| PlannedPage {
                source_page: *page,
            })
            .collect();

        if profile.odd_order == PageOrder::Reversed {
            odd.reverse();
        }
        if profile.even_order == PageOrder::Reversed {
            even.reverse();
        }

        DuplexPlan {
            odd_pass: odd,
            even_pass: even,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::PrinterProfile;

    fn pages(plan: &[PlannedPage]) -> Vec<Option<usize>> {
        plan.iter().map(|p| p.source_page).collect()
    }

    #[test]
    fn new_profile_defaults_to_reverse_odd_and_reverse_even() {
        let profile = PrinterProfile::new("test".into());
        assert_eq!(profile.odd_order, PageOrder::Reversed);
        assert_eq!(profile.even_order, PageOrder::Reversed);
    }

    #[test]
    fn odd_document_pads_then_reverses_even_pass() {
        let mut profile = PrinterProfile::new("test".into());
        profile.odd_order = PageOrder::Normal;
        profile.even_order = PageOrder::Reversed;
        let plan = DuplexPlanner::plan(5, &profile);
        assert_eq!(pages(&plan.odd_pass), vec![Some(1), Some(3), Some(5)]);
        assert_eq!(pages(&plan.even_pass), vec![None, Some(4), Some(2)]);
    }

    #[test]
    fn default_order_for_three_page_document() {
        let plan = DuplexPlanner::plan(3, &PrinterProfile::new("test".into()));
        assert_eq!(pages(&plan.odd_pass), vec![Some(3), Some(1)]);
        assert_eq!(pages(&plan.even_pass), vec![None, Some(2)]);
    }

    #[test]
    fn default_order_for_five_page_document() {
        let plan = DuplexPlanner::plan(5, &PrinterProfile::new("test".into()));
        assert_eq!(pages(&plan.odd_pass), vec![Some(5), Some(3), Some(1)]);
        assert_eq!(pages(&plan.even_pass), vec![None, Some(4), Some(2)]);
    }

    #[test]
    fn default_nine_page_order_needs_no_resorting() {
        let plan = DuplexPlanner::plan(9, &PrinterProfile::new("test".into()));
        assert_eq!(
            pages(&plan.odd_pass),
            vec![Some(9), Some(7), Some(5), Some(3), Some(1)]
        );
        assert_eq!(
            pages(&plan.even_pass),
            vec![None, Some(8), Some(6), Some(4), Some(2)]
        );

        for (front, back) in pages(&plan.odd_pass)
            .into_iter()
            .zip(pages(&plan.even_pass))
        {
            assert_eq!(back.unwrap_or(10), front.unwrap_or(0) + 1);
        }
    }

    #[test]
    fn default_order_pairs_every_sheet_for_odd_and_even_lengths() {
        for page_count in 2..=20 {
            let plan = DuplexPlanner::plan(page_count, &PrinterProfile::new("test".into()));
            let mut output_stack: Vec<Option<usize>> = Vec::new();
            for page in &plan.odd_pass {
                output_stack.insert(0, page.source_page);
            }
            let feed_order: Vec<_> = output_stack.into_iter().rev().collect();
            assert_eq!(feed_order.len(), plan.even_pass.len(), "{page_count} pages");
            for (front, back) in feed_order.iter().zip(pages(&plan.even_pass)) {
                let front_page = front.expect("odd pass must not contain blanks");
                if let Some(back) = back {
                    assert_eq!(back, front_page + 1, "{page_count} pages");
                } else {
                    assert!(
                        page_count % 2 == 1 && front_page == page_count,
                        "{page_count} pages: blank only behind the last page"
                    );
                }
            }
            assert_eq!(
                plan.even_pass.iter().filter(|p| p.source_page.is_none()).count(),
                page_count % 2,
                "{page_count} pages"
            );
        }
    }

    #[test]
    fn combined_plan_starts_every_file_on_a_new_sheet() {
        let plan = DuplexPlanner::plan_counts(&[3, 2, 1], &PrinterProfile::new("test".into()));
        assert_eq!(
            pages(&plan.odd_pass),
            vec![Some(6), Some(4), Some(3), Some(1)]
        );
        assert_eq!(pages(&plan.even_pass), vec![None, Some(5), None, Some(2)]);
    }

    #[test]
    fn combined_plan_pairs_every_sheet_without_resorting() {
        let length_sets: &[&[usize]] = &[
            &[1, 1],
            &[2, 3],
            &[3, 3, 3],
            &[5, 1, 4, 2],
            &[7, 8, 1, 2, 9],
        ];
        for page_counts in length_sets {
            let plan = DuplexPlanner::plan_counts(page_counts, &PrinterProfile::new("test".into()));
            let mut file_of_page = std::collections::HashMap::new();
            let mut offset = 0usize;
            for (file, &count) in page_counts.iter().enumerate() {
                for page in 1..=count {
                    file_of_page.insert(offset + page, file);
                }
                offset += count;
            }

            let mut output_stack: Vec<Option<usize>> = Vec::new();
            for page in &plan.odd_pass {
                output_stack.insert(0, page.source_page);
            }
            let feed_order: Vec<_> = output_stack.into_iter().rev().collect();
            assert_eq!(feed_order.len(), plan.even_pass.len(), "{page_counts:?}");
            for (front, back) in feed_order.iter().zip(pages(&plan.even_pass)) {
                let front = front.expect("odd pass must not contain blanks");
                if let Some(back) = back {
                    assert_eq!(back, front + 1, "{page_counts:?}");
                    assert_eq!(
                        file_of_page.get(&back),
                        file_of_page.get(&front),
                        "{page_counts:?}: a sheet must not mix files"
                    );
                } else {
                    let file = file_of_page[&front];
                    assert_ne!(
                        file_of_page.get(&(front + 1)).copied(),
                        Some(file),
                        "{page_counts:?}: blank only behind a file's last page"
                    );
                }
            }
            assert_eq!(
                plan.even_pass.iter().filter(|p| p.source_page.is_none()).count(),
                page_counts.iter().filter(|c| **c % 2 != 0).count(),
                "{page_counts:?}"
            );
        }
    }

    #[test]
    fn single_page_document_feeds_one_blank_even_page() {
        let plan = DuplexPlanner::plan(1, &PrinterProfile::new("test".into()));
        assert_eq!(pages(&plan.odd_pass), vec![Some(1)]);
        assert_eq!(pages(&plan.even_pass), vec![None]);
    }

    #[test]
    fn orders_are_independently_configurable() {
        let mut profile = PrinterProfile::new("test".into());
        profile.odd_order = PageOrder::Reversed;
        profile.even_order = PageOrder::Normal;
        let plan = DuplexPlanner::plan(6, &profile);
        assert_eq!(pages(&plan.odd_pass), vec![Some(5), Some(3), Some(1)]);
        assert_eq!(pages(&plan.even_pass), vec![Some(2), Some(4), Some(6)]);
    }

    #[test]
    fn empty_document_produces_empty_plan() {
        let plan = DuplexPlanner::plan(0, &PrinterProfile::new("test".into()));
        assert!(plan.odd_pass.is_empty());
        assert!(plan.even_pass.is_empty());
    }
}
