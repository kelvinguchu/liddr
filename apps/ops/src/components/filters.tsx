import { useState } from "react";
import { CheckIcon, ChevronDownIcon, SlidersHorizontalIcon, XIcon } from "lucide-react";
import { BottomSheet, SheetOption } from "@/components/bottom-sheet";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

export interface Filter {
  key: string;
  label: string;
  options: readonly (readonly [value: string, text: string])[];
  value: string;
  fallback: string;
  /** Set elsewhere on the page (an account chip, say), but counted and cleared here. */
  hidden?: boolean;
}

type Values = Record<string, string>;

/**
 * A list's filters. From tablet width they are selects in a row with Clear.
 * On a phone a button at the bottom right, in the thumb's reach, opens them in
 * a sheet; each opens its own list of options, and Done applies them together.
 */
export function Filters({ filters, onApply }: { filters: Filter[]; onApply: (values: Values) => void }) {
  const current: Values = Object.fromEntries(filters.map((f) => [f.key, f.value]));
  const active = filters.filter((f) => f.value !== f.fallback).length;
  const reset = () => onApply(Object.fromEntries(filters.map((f) => [f.key, f.fallback])));
  const shown = filters.filter((f) => !f.hidden);
  const [open, setOpen] = useState(false);

  return (
    <>
      <div className="hidden flex-wrap items-center gap-3 md:flex">
        {shown.map((f) => (
          <Select key={f.key} value={f.value} onValueChange={(value) => onApply({ ...current, [f.key]: value })}>
            <SelectTrigger className="w-52" aria-label={f.label}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent position="popper" align="start">
              {f.options.map(([value, text]) => (
                <SelectItem key={value} value={value}>
                  {text}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        ))}
        {active > 0 ? (
          <Button variant="ghost" size="sm" onClick={reset}>
            Clear
          </Button>
        ) : null}
      </div>

      <div className="fixed right-4 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-40 flex flex-col items-center gap-3 md:hidden">
        {active > 0 ? (
          <Button variant="outline" size="icon" aria-label="Clear filters" onClick={reset} className="size-12 rounded-full bg-background shadow-lg">
            <XIcon className="size-5" />
          </Button>
        ) : null}
        <button
          type="button"
          aria-label={active ? `Filters, ${active} active` : "Filters"}
          onClick={() => setOpen(true)}
          className="relative grid size-14 place-items-center rounded-full bg-brand text-brand-foreground shadow-lg shadow-brand/30 transition-colors active:brightness-95"
        >
          <SlidersHorizontalIcon className="size-5" />
          {active > 0 ? (
            <span aria-hidden className="absolute -top-1 -right-1 grid h-5 min-w-5 place-items-center rounded-full bg-primary px-1 text-micro font-bold text-primary-foreground tnum">
              {active}
            </span>
          ) : null}
        </button>
      </div>
      {open ? <FilterSheet filters={shown} current={current} onClose={() => setOpen(false)} onApply={onApply} /> : null}
    </>
  );
}

function FilterSheet({ filters, current, onClose, onApply }: { filters: Filter[]; current: Values; onClose: () => void; onApply: (values: Values) => void }) {
  const [staged, setStaged] = useState<Values>(current);
  const [choosing, setChoosing] = useState<Filter | null>(null);
  const textOf = (f: Filter) => f.options.find(([value]) => value === staged[f.key])?.[1] ?? "Any";
  return (
    <BottomSheet
      open
      onOpenChange={(open) => !open && onClose()}
      title="Filters"
      footer={
        <Button
          className="h-11 w-full"
          onClick={() => {
            onClose();
            if (filters.some((f) => staged[f.key] !== current[f.key])) onApply(staged);
          }}
        >
          Done
        </Button>
      }
    >
      <div className="flex flex-col gap-4">
        {filters.map((f) => (
          <div key={f.key} className="flex flex-col gap-1.5">
            <span className="text-cell font-medium">{f.label}</span>
            <button type="button" aria-haspopup="dialog" onClick={() => setChoosing(f)} className="flex h-11 w-full items-center justify-between gap-2 rounded-md border border-input bg-background px-3 text-left text-body">
              <span className="truncate">{textOf(f)}</span>
              <ChevronDownIcon className="size-4 shrink-0 text-muted-foreground" />
            </button>
          </div>
        ))}
      </div>
      {choosing ? (
        <BottomSheet open onOpenChange={(open) => !open && setChoosing(null)} title={choosing.label}>
          <div className="flex flex-col gap-2">
            {choosing.options.map(([value, text]) => (
              <SheetOption
                key={value}
                active={staged[choosing.key] === value}
                onSelect={() => {
                  setStaged({ ...staged, [choosing.key]: value });
                  setChoosing(null);
                }}
              >
                <span className="flex-1">{text}</span>
                {staged[choosing.key] === value ? <CheckIcon /> : null}
              </SheetOption>
            ))}
          </div>
        </BottomSheet>
      ) : null}
    </BottomSheet>
  );
}
