// Per-property row editors for the frontmatter panel, extracted from
// WikiPropertiesEditor. `PropertyRow` renders one editable property (type
// picker + key input + a type-specific value editor); `ValueInput` dispatches
// on the row type; `ListEditor` edits list items individually. All state lives
// in the parent — these are controlled via `onPatch` / `onCommit` callbacks.

import { useState } from "react";
import {
  AlignLeft,
  Calendar,
  CalendarClock,
  CheckSquare,
  Hash,
  List as ListIcon,
  Lock,
  Plus,
  Trash2,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  type PropType,
  type PropertyRowState,
  TYPE_ORDER,
  toDateInput,
  toDatetimeInput,
} from "./frontmatterModel";

const TYPE_ICON: Record<PropType, typeof AlignLeft> = {
  text: AlignLeft,
  number: Hash,
  checkbox: CheckSquare,
  list: ListIcon,
  date: Calendar,
  datetime: CalendarClock,
};

const TYPE_LABEL: Record<PropType, string> = {
  text: "Text",
  number: "Number",
  checkbox: "Checkbox",
  list: "List",
  date: "Date",
  datetime: "Date & time",
};

interface RowProps {
  row: PropertyRowState;
  disabled: boolean;
  onPatch: (patch: Partial<PropertyRowState>) => void;
  onCommit: () => void;
  onRemove: () => void;
}

export function PropertyRow({ row, disabled, onPatch, onCommit, onRemove }: RowProps) {
  const Icon = row.readOnly ? Lock : TYPE_ICON[row.type];
  const [typeOpen, setTypeOpen] = useState(false);

  // Read-only row: show the verbatim source, never editable, never dropped.
  if (row.readOnly) {
    return (
      <div className="group grid grid-cols-[minmax(6rem,38%)_1fr_auto] items-center gap-x-2 px-3 py-1">
        <div className="flex min-w-0 items-center gap-1.5">
          <div className="flex size-5 shrink-0 items-center justify-center text-[color:var(--color-text-quaternary)]">
            <Lock className="size-3.5" />
          </div>
          <span
            className="truncate px-1 text-sm text-[color:var(--color-text-secondary)]"
            title={`${row.key} (read-only: preserved verbatim)`}
          >
            {row.key}
          </span>
        </div>
        <div className="min-w-0">
          <span className="block truncate px-1 text-sm text-[color:var(--color-text-quaternary)]">
            preserved verbatim
          </span>
        </div>
        <span aria-hidden className="size-6" />
      </div>
    );
  }

  return (
    <div className="group grid grid-cols-[minmax(6rem,38%)_1fr_auto] items-center gap-x-2 px-3 py-1">
      {/* Key cell: type icon (click to cycle type) + key input */}
      <div className="flex min-w-0 items-center gap-1.5">
        <div className="relative">
          <button
            type="button"
            disabled={disabled}
            aria-label={`Type: ${TYPE_LABEL[row.type]}`}
            title={`Type: ${TYPE_LABEL[row.type]}`}
            onClick={() => setTypeOpen((v) => !v)}
            className="flex size-5 shrink-0 items-center justify-center rounded text-[color:var(--color-text-quaternary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-text-secondary)]"
          >
            <Icon className="size-3.5" />
          </button>
          {typeOpen && (
            <div
              className="absolute left-0 top-6 z-10 flex flex-col rounded-md border border-[color:var(--border)] bg-[color:var(--popover,var(--background))] py-1 shadow-md"
              role="menu"
            >
              {TYPE_ORDER.map((t) => {
                const TIcon = TYPE_ICON[t];
                return (
                  <button
                    key={t}
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setTypeOpen(false);
                      if (t !== row.type) {
                        onPatch(coerceType(row, t));
                        onCommit();
                      }
                    }}
                    className={cn(
                      "flex items-center gap-2 px-3 py-1 text-left text-sm hover:bg-[color:var(--color-surface-hover)]",
                      t === row.type && "text-foreground",
                    )}
                  >
                    <TIcon className="size-3.5" />
                    {TYPE_LABEL[t]}
                  </button>
                );
              })}
            </div>
          )}
        </div>
        <Input
          value={row.key}
          disabled={disabled}
          placeholder="property"
          aria-label="Property name"
          onChange={(e) => onPatch({ key: e.currentTarget.value })}
          onBlur={onCommit}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
          }}
          className="h-7 border-transparent px-1 text-sm hover:border-[color:var(--border)] focus-visible:border-[color:var(--border)] focus-visible:ring-0"
        />
      </div>

      {/* Value cell: typed editor */}
      <div className="min-w-0">
        <ValueInput row={row} disabled={disabled} onPatch={onPatch} onCommit={onCommit} />
      </div>

      {/* Remove */}
      <button
        type="button"
        disabled={disabled}
        aria-label={`Remove ${row.key || "property"}`}
        onClick={onRemove}
        className="flex size-6 items-center justify-center rounded text-[color:var(--color-text-quaternary)] opacity-0 transition-opacity hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-danger,#e5484d)] group-hover:opacity-100"
      >
        <Trash2 className="size-3.5" />
      </button>
    </div>
  );
}

function ValueInput({
  row,
  disabled,
  onPatch,
  onCommit,
}: {
  row: PropertyRowState;
  disabled: boolean;
  onPatch: (patch: Partial<PropertyRowState>) => void;
  onCommit: () => void;
}) {
  const baseInput =
    "h-7 border-transparent px-1 text-sm hover:border-[color:var(--border)] focus-visible:border-[color:var(--border)] focus-visible:ring-0";

  if (row.type === "checkbox") {
    return (
      <input
        type="checkbox"
        disabled={disabled}
        checked={row.bool}
        aria-label="Value"
        onChange={(e) => {
          onPatch({ bool: e.currentTarget.checked });
          // Checkboxes commit immediately (no blur).
          queueMicrotask(onCommit);
        }}
        className="size-4 accent-[color:var(--primary,#3b82f6)]"
      />
    );
  }

  if (row.type === "number") {
    // Keep the raw token verbatim (text input, not number) so leading-zero /
    // long-id strings the user TYPED are preserved exactly. Serialization will
    // emit unsafe numbers as quoted text.
    return (
      <Input
        type="text"
        inputMode="decimal"
        disabled={disabled}
        value={row.raw}
        aria-label="Value"
        onChange={(e) => onPatch({ raw: e.currentTarget.value })}
        onBlur={onCommit}
        onKeyDown={(e) => {
          if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
        }}
        className={baseInput}
      />
    );
  }

  if (row.type === "list") {
    // Structured list editor: each item is its own input so values containing
    // commas are never split irreversibly.
    return <ListEditor row={row} disabled={disabled} onPatch={onPatch} onCommit={onCommit} />;
  }

  if (row.type === "date") {
    return (
      <Input
        type="date"
        disabled={disabled}
        value={toDateInput(row.raw)}
        aria-label="Value"
        onChange={(e) => onPatch({ raw: e.currentTarget.value })}
        onBlur={onCommit}
        className={baseInput}
      />
    );
  }

  if (row.type === "datetime") {
    return (
      <Input
        type="datetime-local"
        disabled={disabled}
        value={toDatetimeInput(row.raw)}
        aria-label="Value"
        onChange={(e) => onPatch({ raw: e.currentTarget.value })}
        onBlur={onCommit}
        className={baseInput}
      />
    );
  }

  // text
  return (
    <Input
      type="text"
      disabled={disabled}
      value={row.raw}
      placeholder="empty"
      aria-label="Value"
      onChange={(e) => onPatch({ raw: e.currentTarget.value })}
      onBlur={onCommit}
      onKeyDown={(e) => {
        if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
      }}
      className={baseInput}
    />
  );
}

/**
 * Per-item list editor. Items are edited individually (no comma-splitting), so
 * a value like "Doe, John" survives intact. Add / remove items inline.
 */
function ListEditor({
  row,
  disabled,
  onPatch,
  onCommit,
}: {
  row: PropertyRowState;
  disabled: boolean;
  onPatch: (patch: Partial<PropertyRowState>) => void;
  onCommit: () => void;
}) {
  const baseInput =
    "h-7 border-transparent px-1 text-sm hover:border-[color:var(--border)] focus-visible:border-[color:var(--border)] focus-visible:ring-0";

  const setItem = (idx: number, value: string) => {
    const list = row.list.slice();
    list[idx] = value;
    onPatch({ list });
  };
  const removeItem = (idx: number) => {
    const list = row.list.slice();
    list.splice(idx, 1);
    onPatch({ list });
    queueMicrotask(onCommit);
  };
  const addItem = () => {
    onPatch({ list: [...row.list, ""] });
  };

  return (
    <div className="flex flex-col gap-1 py-0.5">
      {row.list.map((item, idx) => (
        <div key={idx} className="flex items-center gap-1">
          <Input
            type="text"
            disabled={disabled}
            value={item}
            placeholder="item"
            aria-label={`List item ${idx + 1}`}
            onChange={(e) => setItem(idx, e.currentTarget.value)}
            onBlur={onCommit}
            onKeyDown={(e) => {
              if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
            }}
            className={baseInput}
          />
          <button
            type="button"
            disabled={disabled}
            aria-label={`Remove list item ${idx + 1}`}
            onClick={() => removeItem(idx)}
            className="flex size-6 shrink-0 items-center justify-center rounded text-[color:var(--color-text-quaternary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-danger,#e5484d)]"
          >
            <X className="size-3.5" />
          </button>
        </div>
      ))}
      <Button
        type="button"
        variant="ghost"
        size="sm"
        disabled={disabled}
        onClick={addItem}
        className="h-6 w-fit gap-1 px-1.5 text-xs text-[color:var(--color-text-tertiary)]"
      >
        <Plus className="size-3" />
        Add item
      </Button>
    </div>
  );
}

/** Coerce a row's held value when its type changes, best-effort. */
function coerceType(row: PropertyRowState, next: PropType): Partial<PropertyRowState> {
  // Best-effort current scalar representation of the row.
  const current =
    row.type === "checkbox"
      ? row.bool
        ? "true"
        : "false"
      : row.type === "list"
        ? row.list.join(", ")
        : row.raw;

  switch (next) {
    case "checkbox":
      return { type: next, bool: current.trim() === "true", raw: "", list: [] };
    case "list":
      // When coming from a non-list, seed a single item with the whole value
      // (no comma-split) so commas in the scalar survive.
      return {
        type: next,
        list: row.type === "list" ? row.list : current.trim() === "" ? [] : [current],
        raw: "",
        bool: false,
      };
    case "number":
    case "date":
    case "datetime":
    case "text":
    default:
      return { type: next, raw: current, bool: false, list: [] };
  }
}
