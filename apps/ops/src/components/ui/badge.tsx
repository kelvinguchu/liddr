import type * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex h-[22px] shrink-0 items-center gap-1 whitespace-nowrap rounded-full border px-2 text-meta font-medium leading-none [&>svg]:size-3",
  {
    variants: {
      variant: {
        default: "border-border bg-muted text-muted-foreground",
        outline: "border-border text-foreground",
        brand: "border-brand/40 bg-brand/10 dark:bg-brand/14 text-brand-ink",
        info: "border-info/30 bg-info/8 dark:bg-info/12 text-info",
        ok: "border-ok/30 bg-ok/8 dark:bg-ok/12 text-ok",
        warn: "border-warn/35 bg-warn/8 dark:bg-warn/12 text-warn",
        crit: "border-crit/35 bg-crit/8 dark:bg-crit/12 text-crit",
        none: "border-border bg-muted text-muted-foreground",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

export type BadgeVariant = NonNullable<VariantProps<typeof badgeVariants>["variant"]>;

function Badge({ className, variant, ...props }: React.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
  return <span data-slot="badge" className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
