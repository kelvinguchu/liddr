import type * as React from "react";
import { cn } from "@/lib/utils";

// Tables bound their row count instead of scrolling (see DataTable). A table
// wider than its panel scrolls sideways as a last resort; it never clips.
function Table({ className, containerClassName, ...props }: React.ComponentProps<"table"> & { containerClassName?: string }) {
  return (
    <div data-slot="table-container" className={cn("relative w-full overflow-x-auto", containerClassName)}>
      <table data-slot="table" className={cn("w-full caption-bottom border-separate border-spacing-0 text-cell tnum", className)} {...props} />
    </div>
  );
}

function TableHeader({ className, ...props }: React.ComponentProps<"thead">) {
  return <thead data-slot="table-header" className={cn(className)} {...props} />;
}

function TableBody({ className, ...props }: React.ComponentProps<"tbody">) {
  return <tbody data-slot="table-body" className={cn("[&_tr:last-child_td]:border-b-0", className)} {...props} />;
}

function TableRow({ className, ...props }: React.ComponentProps<"tr">) {
  return <tr data-slot="table-row" className={cn("transition-colors hover:bg-accent/50", className)} {...props} />;
}

function TableHead({ className, ...props }: React.ComponentProps<"th">) {
  return (
    <th
      data-slot="table-head"
      className={cn("h-8 whitespace-nowrap border-b px-2.5 text-left align-middle text-meta font-normal text-muted-foreground first:pl-2 last:pr-2", className)}
      {...props}
    />
  );
}

function TableCell({ className, ...props }: React.ComponentProps<"td">) {
  return <td data-slot="table-cell" className={cn("h-8 whitespace-nowrap border-b border-border/60 px-2.5 py-1 align-middle first:pl-2 last:pr-2", className)} {...props} />;
}

export { Table, TableHeader, TableBody, TableRow, TableHead, TableCell };
