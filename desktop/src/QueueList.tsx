import { useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { useTranslation } from "react-i18next";
import {
  DndContext,
  DragEndEvent,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
} from "@dnd-kit/core";
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { ImageQueueItem, PdfQueueItem } from "./types";

type QueueItem = PdfQueueItem | ImageQueueItem;

const SWIPE_OPEN = 88;
const SWIPE_COMMIT = 140;

function fileName(path: string): string {
  return path.split(/[/\\]/).pop() ?? path;
}

function statusKey(status: string): string {
  return `status.${status}`;
}

interface QueueListProps {
  items: QueueItem[];
  isImages: boolean;
  locked: boolean;
  onReorder: (items: QueueItem[]) => void;
  onRemove: (index: number) => void;
  onPreview: (path: string) => void;
}

export function QueueList({
  items,
  isImages,
  locked,
  onReorder,
  onRemove,
  onPreview,
}: QueueListProps) {
  const ids = useMemo(() => items.map((item) => item.id), [items]);
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    }),
  );

  function handleDragEnd(event: DragEndEvent) {
    if (locked) return;
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const oldIndex = items.findIndex((item) => item.id === active.id);
    const newIndex = items.findIndex((item) => item.id === over.id);
    if (oldIndex < 0 || newIndex < 0) return;
    onReorder(arrayMove(items, oldIndex, newIndex));
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      onDragEnd={handleDragEnd}
    >
      <SortableContext items={ids} strategy={verticalListSortingStrategy}>
        <ul className="queue-list">
          {items.map((item, index) => (
            <SortableQueueRow
              key={item.id}
              item={item}
              index={index}
              isImages={isImages}
              locked={locked}
              onRemove={() => onRemove(index)}
              onPreview={() => onPreview(item.path)}
            />
          ))}
        </ul>
      </SortableContext>
    </DndContext>
  );
}

function SortableQueueRow({
  item,
  index,
  isImages,
  locked,
  onRemove,
  onPreview,
}: {
  item: QueueItem;
  index: number;
  isImages: boolean;
  locked: boolean;
  onRemove: () => void;
  onPreview: () => void;
}) {
  const { t } = useTranslation();
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: item.id, disabled: locked });

  const [offset, setOffset] = useState(0);
  const [open, setOpen] = useState(false);
  const startX = useRef(0);
  const startY = useRef(0);
  const baseOffset = useRef(0);
  const axis = useRef<"undecided" | "x" | "y">("undecided");
  const swiping = useRef(false);

  const detail = [
    "pageCount" in item
      ? t("queue.pageCount", { count: item.pageCount })
      : t("queue.pageNumber", { count: index + 1 }),
    t(statusKey(item.status)),
  ].join(" · ");

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    zIndex: isDragging ? 2 : undefined,
    opacity: isDragging ? 0.92 : 1,
  };

  function clampSwipe(value: number) {
    return Math.min(0, Math.max(-SWIPE_COMMIT - 40, value));
  }

  function onPointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (locked || event.button !== 0) return;
    // Ignore presses on interactive controls / drag handle.
    const target = event.target as HTMLElement;
    if (target.closest("button, a, .drag-handle")) return;
    startX.current = event.clientX;
    startY.current = event.clientY;
    baseOffset.current = open ? -SWIPE_OPEN : 0;
    axis.current = "undecided";
    swiping.current = true;
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function onPointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    if (!swiping.current) return;
    const dx = event.clientX - startX.current;
    const dy = event.clientY - startY.current;
    if (axis.current === "undecided") {
      if (Math.abs(dx) < 6 && Math.abs(dy) < 6) return;
      axis.current = Math.abs(dx) > Math.abs(dy) ? "x" : "y";
      if (axis.current === "y") {
        swiping.current = false;
        return;
      }
    }
    if (axis.current !== "x") return;
    event.preventDefault();
    setOffset(clampSwipe(baseOffset.current + dx));
  }

  function finishSwipe() {
    if (!swiping.current && axis.current !== "x") {
      setOffset(open ? -SWIPE_OPEN : 0);
      return;
    }
    swiping.current = false;
    if (offset <= -SWIPE_COMMIT) {
      setOpen(false);
      setOffset(0);
      onRemove();
      return;
    }
    if (offset <= -SWIPE_OPEN / 2) {
      setOpen(true);
      setOffset(-SWIPE_OPEN);
    } else {
      setOpen(false);
      setOffset(0);
    }
  }

  function onPointerUp() {
    if (axis.current === "x") finishSwipe();
    swiping.current = false;
    axis.current = "undecided";
  }

  return (
    <li
      ref={setNodeRef}
      className={`queue-row ${isDragging ? "dragging" : ""} ${open ? "swiped" : ""}`}
      style={style}
    >
      <button
        type="button"
        className="swipe-delete"
        disabled={locked}
        onClick={onRemove}
        tabIndex={open ? 0 : -1}
      >
        {t("queue.remove")}
      </button>

      <div
        className="queue-row-front"
        style={{ transform: `translateX(${offset}px)` }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <button
          type="button"
          className="drag-handle"
          disabled={locked}
          title={t("queue.moveLater")}
          aria-label={t("queue.moveLater")}
          {...attributes}
          {...listeners}
        >
          ⠿
        </button>
        <div className={`row-icon ${isImages ? "image" : "pdf"}`}>
          {isImages ? "🖼" : "📄"}
        </div>
        <div className="row-main">
          <strong>{fileName(item.path)}</strong>
          <span className={item.status}>{detail}</span>
        </div>
        <div className="row-actions">
          <button
            type="button"
            className="btn btn-icon"
            title={t("queue.preview")}
            onClick={onPreview}
          >
            👁
          </button>
        </div>
      </div>
    </li>
  );
}
