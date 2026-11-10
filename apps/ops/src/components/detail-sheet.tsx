import type { ReactNode } from "react";
import { AlertCircleIcon } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { problemText } from "@/lib/api";
import { cn } from "@/lib/utils";

// A record opens in a sheet from the right: the full screen on a phone, half
// of it from tablet width. Its header names the kind of record (the eyebrow),
// the record and what can be done to it; the body holds figures and details.
export function DetailSheet({
  open,
  onClose,
  eyebrow,
  title,
  subtitle,
  actions,
  error,
  onRetry,
  children,
}: {
  open: boolean;
  onClose: () => void;
  eyebrow: string;
  title?: string;
  subtitle?: ReactNode;
  actions?: ReactNode;
  error?: unknown;
  onRetry?: () => void;
  children?: ReactNode;
}) {
  return (
    <Sheet open={open} onOpenChange={(next) => !next && onClose()}>
      <SheetContent side="right" className="w-full gap-0 p-0 sm:max-w-none md:w-[clamp(600px,50vw,780px)]" onOpenAutoFocus={(e) => e.preventDefault()}>
        <div className="flex flex-col gap-3 border-b px-4 pt-5 pb-4 sm:px-6">
          <div className="min-w-0 pe-10">
            <p className="text-micro font-semibold tracking-[0.12em] text-brand-ink uppercase">{eyebrow}</p>
            {title ? (
              <SheetTitle className="mt-1 truncate text-title tracking-tight">{title}</SheetTitle>
            ) : (
              <>
                <SheetTitle className="sr-only">Loading</SheetTitle>
                <Skeleton className="mt-2 h-5 w-48" />
              </>
            )}
            <SheetDescription className={cn("mt-0.5 text-cell text-muted-foreground", !subtitle && "sr-only")}>{subtitle ?? eyebrow}</SheetDescription>
          </div>
          {actions ? <div className="grid grid-cols-2 gap-2 sm:flex sm:flex-wrap sm:items-center [&>*:only-child]:col-span-2">{actions}</div> : null}
        </div>
        <div className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-4 pt-5 pb-[calc(2rem+env(safe-area-inset-bottom))] sm:px-6 [&>*]:shrink-0">
          {error ? (
            <Alert variant="destructive">
              <AlertCircleIcon />
              <AlertDescription className="flex flex-col items-start gap-2">
                <span>{problemText(error)}</span>
                {onRetry ? (
                  <Button variant="outline" size="sm" onClick={onRetry}>
                    Try again
                  </Button>
                ) : null}
              </AlertDescription>
            </Alert>
          ) : title ? (
            children
          ) : (
            <div className="flex flex-col gap-3" role="status" aria-label="Loading">
              <Skeleton className="h-20 w-full" />
              <Skeleton className="h-32 w-full" />
            </div>
          )}
        </div>
      </SheetContent>
    </Sheet>
  );
}

/** Headline figures. The one marked brand is what the reviewer should act on. */
export function DetailStats({ items }: { items: { label: string; value: ReactNode; tone?: "brand" | "warn" }[] }) {
  return (
    <div className="grid grid-cols-2 overflow-hidden rounded-xl border sm:auto-cols-fr sm:grid-flow-col sm:grid-cols-none">
      {items.map((item, i) => (
        <div
          key={item.label}
          className={cn(
            "flex min-w-0 flex-col gap-1 px-4 py-3.5",
            i % 2 === 1 && "border-l",
            i > 1 && "border-t sm:border-t-0",
            i > 0 && "sm:border-l",
            item.tone === "brand" && "bg-brand/6",
          )}
        >
          <span className="text-meta font-medium text-muted-foreground">{item.label}</span>
          <span className={cn("text-figure-sm font-semibold break-words tnum", item.tone === "brand" && "text-brand-ink", item.tone === "warn" && "text-destructive")}>{item.value}</span>
        </div>
      ))}
    </div>
  );
}

export function DetailSection({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <div className="flex min-h-8 items-center justify-between gap-3">
        <h3 className="text-meta font-semibold tracking-wide text-muted-foreground uppercase">{title}</h3>
        {action}
      </div>
      {children}
    </section>
  );
}

/** Label and value rows. An empty value shows as a dash. */
export function DetailRows({ rows }: { rows: [label: string, value: ReactNode][] }) {
  return (
    <dl className="divide-y rounded-xl border">
      {rows.map(([name, value]) => (
        <div key={name} className="flex items-baseline justify-between gap-4 px-4 py-3">
          <dt className="shrink-0 text-cell text-muted-foreground">{name}</dt>
          <dd className="min-w-0 text-right text-cell font-medium break-words">{value === undefined || value === null || value === "" ? "—" : value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Mono({ children }: { children: ReactNode }) {
  return <span className="font-mono text-[0.8em]">{children}</span>;
}
