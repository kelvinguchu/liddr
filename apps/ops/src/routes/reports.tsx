import { createFileRoute } from "@tanstack/react-router";
import { Filters } from "@/components/filters";
import { PageHeader } from "@/components/page-header";
import { RecordList } from "@/components/record-list";
import { ReportSheet } from "@/components/reports/report-sheet";
import { SeverityBadge, StatusBadge } from "@/components/status-badge";
import { api, type Schemas } from "@/lib/api";
import { label, shortID, when } from "@/lib/format";
import { usePagedList } from "@/lib/lists";
import { oneOf, optionalText, type Options, type SearchIn } from "@/lib/search";

type Status = "submitted" | "triaged" | "under_review" | "resolved" | "dismissed";

const STATUSES: Options<Status> = [
  ["submitted", "New"],
  ["triaged", "Triaged"],
  ["under_review", "Under review"],
  ["resolved", "Resolved"],
  ["dismissed", "Dismissed"],
];

export const Route = createFileRoute("/reports")({
  validateSearch: (search: SearchIn<{ status: Status; id: string }>): { status: Status; id?: string } => ({
    status: oneOf(search.status, STATUSES, "submitted"),
    id: optionalText(search.id),
  }),
  component: ReportsPage,
});

function ReportsPage() {
  const { status, id } = Route.useSearch();
  const navigate = Route.useNavigate();
  const list = usePagedList(["reports", status], async (limit, offset) => (await api.get("/v1/ops/moderation/reports", { query: { status, limit, offset } })).data);

  return (
    <div className="flex flex-col gap-4 pb-28 md:pb-0">
      <PageHeader title="Reports" description="Most severe first. Start a review before looking into a case, so two people do not work it at once." refreshing={list.isRefetching} onRefresh={() => list.refetch()} />
      <Filters filters={[{ key: "status", label: "Status", options: STATUSES, value: status, fallback: "submitted" }]} onApply={(v) => navigate({ search: { status: oneOf(v.status, STATUSES, "submitted") } })} />
      <RecordList<Schemas["ReportSummary"]>
        query={list}
        rowKey={(r) => r.id}
        onOpen={(r) => navigate({ search: (prev) => ({ ...prev, id: r.id }) })}
        empty={status === "submitted" ? "No new reports." : "No reports in this state."}
        columns={[
          { header: "Severity", cell: (r) => <SeverityBadge level={r.severity} /> },
          { header: "Category", cell: (r) => <span className="font-medium">{label(r.category)}</span> },
          { header: "Incident", cell: (r) => label(r.incident_type) },
          { header: "Source", cell: (r) => label(r.source) },
          { header: "About account", cell: (r) => <span className="font-mono text-meta" title={r.reported_id}>{shortID(r.reported_id)}</span> },
          { header: "Received", cell: (r) => <span className="text-muted-foreground">{when(r.created_at)}</span> },
          { header: "Status", cell: (r) => <StatusBadge status={r.status} /> },
        ]}
        card={(r) => ({
          title: label(r.category),
          status: <StatusBadge status={r.status} />,
          tags: [<SeverityBadge key="sev" level={r.severity} />, <span key="inc">{label(r.incident_type)}</span>],
          meta: [label(r.source), <span key="about">About <span className="font-mono">{shortID(r.reported_id)}</span></span>, when(r.created_at)],
        })}
      />
      <ReportSheet id={id} onClose={() => navigate({ search: (prev) => ({ ...prev, id: undefined }) })} />
    </div>
  );
}
