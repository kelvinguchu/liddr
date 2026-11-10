import type { ReactNode } from "react";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";

// A sheet that rises from the bottom of a phone screen: filters, their
// options and page actions. Wide screens never open one.
export function BottomSheet({ open, onOpenChange, title, footer, children }: { open: boolean; onOpenChange: (open: boolean) => void; title: string; footer?: ReactNode; children: ReactNode }) {
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="bottom" className="max-h-[min(85dvh,calc(100dvh-1.5rem))] gap-0 rounded-t-2xl pb-safe">
        <div aria-hidden className="mx-auto mt-2.5 h-1 w-11 shrink-0 rounded-full bg-border" />
        <SheetHeader className="px-4 pt-2 pb-2">
          <SheetTitle className="text-section">{title}</SheetTitle>
          <SheetDescription className="sr-only">{title}</SheetDescription>
        </SheetHeader>
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-4">{children}</div>
        {footer ? <div className="border-t px-4 pt-3 pb-4">{footer}</div> : null}
      </SheetContent>
    </Sheet>
  );
}

/** A full-width choice row in a bottom sheet. */
export function SheetOption({ active, onSelect, children }: { active?: boolean; onSelect: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-current={active ? "true" : undefined}
      onClick={onSelect}
      className="flex min-h-12 w-full items-center gap-3 rounded-lg border px-3.5 text-left text-body font-medium transition-colors active:bg-muted aria-[current=true]:border-brand/40 aria-[current=true]:bg-brand/10 aria-[current=true]:text-brand-ink [&_svg]:size-4 [&_svg]:shrink-0 [&_svg]:text-muted-foreground aria-[current=true]:[&_svg]:text-brand-ink"
    >
      {children}
    </button>
  );
}
