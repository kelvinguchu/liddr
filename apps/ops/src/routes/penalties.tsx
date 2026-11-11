import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { PlusIcon, SearchIcon, XIcon } from "lucide-react";
import { DetailStats } from "@/components/detail-sheet";
import { Filters } from "@/components/filters";
import { PageHeader } from "@/components/page-header";
import { ApplyPenaltyDialog, LiftPenaltyDialog } from "@/components/penalties/dialogs";
import { RecordList } from "@/components/record-list";
import { StatusBadge } from "@/components/status-badge";
import { Button } from "@/components/ui/button";
import { api, type Schemas } from "@/lib/api";
import { isUUID, label, shortID, when } from "@/lib/format";
import { usePagedList } from "@/lib/lists";
import { oneOf, type Options, type SearchIn } from "@/lib/search";

type Status = "active" | "expired" | "lifted";
type Penalty = Schemas["Enforcement"];

const STATUSES: Options<Status> = [
  ["active", "In force"],
  ["expired", "Expired"],
  ["lifted", "Lifted"],
];

export const Route = createFileRoute("/penalties")({
  validateSearch: (search: SearchIn<{ status: Status; user: string }>): { status: Status; user?: string } => ({
    status: oneOf(search.status, STATUSES, "active"),
    user: typeof search.user === "string" && isUUID(search.user) ? search.user.trim() : undefined,
  }),
  component: PenaltiesPage,
});

function PenaltiesPage() {
  const { status, user } = Route.useSearch();
  const navigate = Route.useNavigate();
  const queryClient = useQueryClient();
  const metrics = useQuery({ queryKey: ["penalty-metrics"], queryFn: () => api.get("/v1/ops/moderation/enforcements/metrics") });
  // The API lists penalties by status only, so an account's are picked out of
  // the rows loaded so far.
  const list = usePagedList(["penalties", status], async (limit, offset) => (await api.get("/v1/ops/moderation/enforcements", { query: { status, limit, offset } })).data);
  const [applying, setApplying] = useState(false);
  const [lifting, setLifting] = useState<Penalty | null>(null);

  const total = (action: string) => (metrics.data?.data ?? []).filter((m) => m.status === "active" && m.action === action).reduce((n, m) => n + m.total, 0);
  const changed = () => Promise.all([queryClient.invalidateQueries({ queryKey: ["penalties"] }), queryClient.invalidateQueries({ queryKey: ["penalty-metrics"] })]);
  const lift = (p: Penalty) =>
    p.status === "active" ? (
      <Button variant="outline" size="sm" onClick={() => setLifting(p)}>
        Lift
      </Button>
    ) : null;

  return (
    <div className="flex flex-col gap-4 pb-28 md:pb-0">
      <PageHeader
        title="Penalties"
        description="Every penalty carries a reason and the staff member who applied it."
        refreshing={list.isRefetching || metrics.isRefetching}
        onRefresh={() => {
          void metrics.refetch();
          void list.refetch();
        }}
        actions={[{ label: "Apply a penalty", icon: PlusIcon, onSelect: () => setApplying(true) }]}
      />
      <DetailStats
        items={[
          { label: "Suspended now", value: metrics.data ? String(total("temporary_suspension")) : "…", tone: "brand" },
          { label: "Banned", value: metrics.data ? String(total("permanent_ban")) : "…" },
          { label: "Restricted", value: metrics.data ? String(total("feature_restriction")) : "…" },
          { label: "Suspensions past their end", value: metrics.data ? String(metrics.data.overdue_suspensions) : "…", tone: metrics.data && metrics.data.overdue_suspensions > 0 ? "warn" : undefined },
        ]}
      />
      {user ? (
        <div className="flex">
          <span className="inline-flex h-8 items-center gap-1.5 rounded-md border border-dashed border-input pr-1 pl-2.5 text-cell font-medium">
            <SearchIcon className="size-3.5 text-muted-foreground" />
            Account <span className="font-mono">{shortID(user)}</span>
            <Button variant="ghost" size="icon-xs" aria-label="Show every account" onClick={() => navigate({ search: { status } })}>
              <XIcon />
            </Button>
          </span>
        </div>
      ) : null}
      <Filters
        filters={[
          { key: "status", label: "Status", options: STATUSES, value: status, fallback: "active" },
          { key: "user", label: "Account", options: [], value: user ?? "", fallback: "", hidden: true },
        ]}
        onApply={(v) => navigate({ search: { status: oneOf(v.status, STATUSES, "active"), user: v.user || undefined } })}
      />
      <RecordList<Penalty>
        query={list}
        keep={user ? (p) => p.user_id === user : undefined}
        rowKey={(p) => p.id}
        empty={user ? "This account has no penalties in the rows loaded so far." : status === "active" ? "No penalties are in force." : `No ${label(status).toLowerCase()} penalties.`}
        columns={[
          { header: "Account", cell: (p) => <span className="font-mono text-meta" title={p.user_id}>{shortID(p.user_id)}</span> },
          { header: "Penalty", cell: (p) => <span className="font-medium">{label(p.action)}</span> },
          { header: "Reason", cell: (p) => <span className="font-mono text-meta">{p.reason_code}</span> },
          { header: "From", cell: (p) => <span className="text-muted-foreground">{when(p.starts_at)}</span> },
          { header: status === "lifted" ? "Lifted" : "Until", cell: (p) => <span className="text-muted-foreground">{status === "lifted" ? when(p.lifted_at) : p.ends_at ? when(p.ends_at) : "No end"}</span> },
          { header: "Status", cell: (p) => <StatusBadge status={p.status} text={p.status === "active" ? "In force" : undefined} /> },
          { header: "", className: "w-px text-right", cell: lift },
        ]}
        card={(p) => ({
          title: label(p.action),
          status: <StatusBadge status={p.status} text={p.status === "active" ? "In force" : undefined} />,
          tags: [<span key="r" className="font-mono text-meta">{p.reason_code}</span>, <span key="a">Account <span className="font-mono">{shortID(p.user_id)}</span></span>],
          meta: [`From ${when(p.starts_at)}`, status === "lifted" ? `Lifted ${when(p.lifted_at)}` : p.ends_at ? `Until ${when(p.ends_at)}` : "No end"],
          actions: lift(p),
        })}
      />
      <ApplyPenaltyDialog open={applying} onOpenChange={setApplying} account={user} onDone={changed} />
      <LiftPenaltyDialog penalty={lifting} onClose={() => setLifting(null)} onDone={changed} />
    </div>
  );
}
