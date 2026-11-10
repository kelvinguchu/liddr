import { useState, type ComponentType } from "react";
import { EllipsisIcon, RefreshCwIcon } from "lucide-react";
import { BottomSheet, SheetOption } from "@/components/bottom-sheet";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

export interface PageAction {
  label: string;
  icon?: ComponentType<{ className?: string }>;
  onSelect: () => void;
}

// The page's title row. Refresh is always its own icon button. Page actions
// are buttons from tablet width up and sit behind ⋯ on a phone. The
// description is guidance for wide screens and is dropped on a phone.
export function PageHeader({ title, description, refreshing, onRefresh, actions = [] }: { title: string; description?: string; refreshing?: boolean; onRefresh?: () => void; actions?: PageAction[] }) {
  const [menu, setMenu] = useState(false);
  return (
    <header className="flex items-start justify-between gap-4">
      <div className="min-w-0 flex-1">
        <h1 className="truncate text-title font-semibold tracking-tight">{title}</h1>
        {description ? <p className="mt-0.5 hidden text-cell text-muted-foreground sm:block">{description}</p> : null}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {onRefresh ? (
          <Button variant="outline" size="icon" className="size-9 md:size-8" aria-label="Refresh" disabled={refreshing} onClick={onRefresh}>
            <RefreshCwIcon className={cn("size-4", refreshing && "animate-spin")} />
          </Button>
        ) : null}
        {actions.map((action) => (
          <Button key={action.label} className="hidden md:inline-flex" onClick={action.onSelect}>
            {action.icon ? <action.icon className="size-4" /> : null}
            {action.label}
          </Button>
        ))}
        {actions.length > 0 ? (
          <>
            <Button variant="outline" size="icon" className="size-9 md:hidden" aria-label="More actions" onClick={() => setMenu(true)}>
              <EllipsisIcon className="size-4" />
            </Button>
            <BottomSheet open={menu} onOpenChange={setMenu} title="Actions">
              <div className="flex flex-col gap-2">
                {actions.map((action) => (
                  <SheetOption
                    key={action.label}
                    onSelect={() => {
                      setMenu(false);
                      action.onSelect();
                    }}
                  >
                    {action.icon ? <action.icon /> : null}
                    <span className="flex-1">{action.label}</span>
                  </SheetOption>
                ))}
              </div>
            </BottomSheet>
          </>
        ) : null}
      </div>
    </header>
  );
}
