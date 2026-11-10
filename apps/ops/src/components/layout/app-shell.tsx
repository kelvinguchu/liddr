import { useEffect, useState, type ComponentType, type ReactNode } from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import { useMutation } from "@tanstack/react-query";
import { BanIcon, BanknoteIcon, FileCheck2Icon, FlagIcon, LogOutIcon, MenuIcon, ReceiptTextIcon, ScaleIcon, ShieldCheckIcon } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { roleLabel } from "@/lib/access";
import { endSession } from "@/lib/api";
import { initials } from "@/lib/format";
import { useAccount } from "@/lib/session";
import { useStepUp } from "@/lib/step-up";

interface NavItem {
  to: string;
  label: string;
  icon: ComponentType<{ className?: string }>;
}

export const NAV: { title: string; items: NavItem[] }[] = [
  {
    title: "Review",
    items: [
      { to: "/documents", label: "Driver documents", icon: FileCheck2Icon },
      { to: "/reports", label: "Reports", icon: FlagIcon },
      { to: "/disputes", label: "Disputes", icon: ScaleIcon },
    ],
  },
  { title: "Enforcement", items: [{ to: "/penalties", label: "Penalties", icon: BanIcon }] },
  {
    title: "Money",
    items: [
      { to: "/payouts", label: "Payouts", icon: BanknoteIcon },
      { to: "/payments", label: "Payments", icon: ReceiptTextIcon },
    ],
  },
];

// The frame: a muted sidebar and top bar around a white working panel with a
// rounded corner. Below 1024px the sidebar becomes a sheet behind the menu
// button, which sits at the right of the top bar next to the logo's opposite.
export function AppShell({ children }: { children: ReactNode }) {
  const [menu, setMenu] = useState(false);
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  useEffect(() => setMenu(false), [pathname]);
  const page = NAV.flatMap((g) => g.items).find((item) => pathname.startsWith(item.to));

  return (
    <div className="flex h-dvh overflow-hidden bg-chrome">
      <aside className="hidden w-64 shrink-0 flex-col lg:flex">
        <Sidebar />
      </aside>
      <Sheet open={menu} onOpenChange={setMenu}>
        <SheetContent side="left" className="w-64 gap-0 border-r-0 bg-chrome p-0 lg:hidden" showCloseButton={false}>
          <SheetTitle className="sr-only">Menu</SheetTitle>
          <SheetDescription className="sr-only">Pages of the staff console</SheetDescription>
          <Sidebar />
        </SheetContent>
      </Sheet>

      <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
        <header className="flex h-14 shrink-0 items-center justify-between gap-3 px-4">
          <div className="flex min-w-0 items-center gap-2">
            <Link to="/documents" aria-label="Liddr Ops home" className="lg:hidden">
              <Logo />
            </Link>
            <nav aria-label="Breadcrumb" className="hidden items-center gap-2 text-cell font-medium text-muted-foreground lg:flex">
              <span>Operations</span>
              <span aria-hidden>/</span>
              <span className="text-foreground">{page?.label ?? "Console"}</span>
            </nav>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <StepUpChip />
            <Button variant="outline" size="icon" className="size-9 bg-background shadow-xs lg:hidden" aria-label="Open menu" onClick={() => setMenu(true)}>
              <MenuIcon className="size-5" />
            </Button>
          </div>
        </header>
        <main className="min-h-0 flex-1 overflow-y-auto bg-background px-3 pt-3 pb-[calc(1.5rem+env(safe-area-inset-bottom))] sm:px-6 sm:pt-6 lg:rounded-tl-2xl lg:border-t lg:border-l">
          <div className="mx-auto flex max-w-[1400px] flex-col gap-4">{children}</div>
        </main>
      </div>
    </div>
  );
}

function Logo() {
  return (
    <>
      <img src="/logo-for-light-mode.svg" alt="liddr" width={74} height={32} className="h-7 w-auto dark:hidden" />
      <img src="/logo-for-dark-mode.svg" alt="liddr" width={74} height={32} className="hidden h-7 w-auto dark:block" />
    </>
  );
}

function Sidebar() {
  return (
    <div className="flex h-full flex-col">
      <div className="flex h-14 shrink-0 items-center gap-2.5 px-5">
        <Logo />
        <span className="rounded-md border border-brand/40 bg-brand/10 px-1.5 text-micro font-bold tracking-[0.12em] text-brand-ink uppercase">Ops</span>
      </div>
      <nav aria-label="Pages" className="flex flex-1 flex-col gap-6 overflow-y-auto px-3 py-4">
        {NAV.map((group) => (
          <div key={group.title}>
            <span className="mb-1.5 block px-3 text-micro font-semibold tracking-widest text-muted-foreground uppercase">{group.title}</span>
            <div className="flex flex-col gap-0.5">
              {group.items.map((item) => (
                <Link
                  key={item.to}
                  to={item.to}
                  className="flex items-center gap-3 rounded-lg px-3 py-2 text-body font-medium text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                  activeProps={{ className: "!bg-brand !text-brand-foreground font-semibold shadow-sm shadow-brand/30", "aria-current": "page" }}
                >
                  <item.icon className="size-[18px] shrink-0" />
                  <span>{item.label}</span>
                </Link>
              ))}
            </div>
          </div>
        ))}
      </nav>
      <UserFooter />
    </div>
  );
}

function UserFooter() {
  const { data: me } = useAccount();
  const out = useMutation({ mutationFn: endSession, onSettled: () => window.location.assign("/signin") });
  const name = me?.display_name || "Staff member";
  return (
    <div className="flex items-center gap-3 border-t p-3">
      <span aria-hidden className="grid size-9 shrink-0 place-items-center rounded-full border border-brand/40 bg-brand/10 text-meta font-bold text-brand-ink">
        {initials(name)}
      </span>
      <div className="min-w-0 flex-1">
        <div className="truncate text-cell font-medium">{name}</div>
        <Badge variant="brand" className="mt-0.5 h-[18px] px-1.5 text-[10.5px]">
          {roleLabel(me?.roles ?? [])}
        </Badge>
      </div>
      <Button variant="ghost" size="icon" aria-label="Sign out" title="Sign out" disabled={out.isPending} onClick={() => out.mutate()}>
        <LogOutIcon className="size-[18px]" />
      </Button>
    </div>
  );
}

// While an authenticator confirmation holds, the top bar says so and for how
// long, so a reviewer knows when they will be asked for a code again.
function StepUpChip() {
  const { expiresAt } = useStepUp();
  // Ticks only to redraw; the time left is always read fresh.
  const [, setTick] = useState(0);
  useEffect(() => {
    if (expiresAt <= Date.now()) return;
    const timer = setInterval(() => setTick((n) => n + 1), 10_000);
    return () => clearInterval(timer);
  }, [expiresAt]);
  const left = expiresAt - Date.now();
  if (left <= 0) return null;
  const minutes = Math.max(1, Math.round(left / 60_000));
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Badge variant="brand" className="h-7 gap-1.5 px-2.5" tabIndex={0}>
          <ShieldCheckIcon className="!size-3.5" />
          <span className="hidden sm:inline">Confirmed · {minutes} min left</span>
          <span className="sm:hidden">{minutes} min</span>
        </Badge>
      </TooltipTrigger>
      <TooltipContent>High-risk actions are confirmed for {minutes} more minute{minutes === 1 ? "" : "s"}.</TooltipContent>
    </Tooltip>
  );
}
