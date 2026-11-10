import { createFileRoute } from "@tanstack/react-router";
import { ApplicationSheet } from "@/components/documents/application-sheet";
import { Filters } from "@/components/filters";
import { PageHeader } from "@/components/page-header";
import { RecordList } from "@/components/record-list";
import { StatusBadge } from "@/components/status-badge";
import { api, type Schemas } from "@/lib/api";
import { label, when } from "@/lib/format";
import { usePagedList } from "@/lib/lists";
import { oneOf, optionalText, type Options, type SearchIn } from "@/lib/search";

type Status = "under_review" | "pending" | "resubmission_required" | "approved" | "rejected" | "suspended";

// Under review comes first: an application lands there once every document is in.
const STATUSES: Options<Status> = [
  ["under_review", "Ready to review"],
  ["pending", "Still uploading"],
  ["resubmission_required", "Waiting on resubmission"],
  ["approved", "Approved"],
  ["rejected", "Rejected"],
  ["suspended", "Suspended"],
];

const EMPTY: Partial<Record<Status, string>> = {
  under_review: "No applications are waiting for review.",
  pending: "No drivers are part way through uploading.",
};

export const Route = createFileRoute("/documents")({
  validateSearch: (search: SearchIn<{ status: Status; id: string }>): { status: Status; id?: string } => ({
    status: oneOf(search.status, STATUSES, "under_review"),
    id: optionalText(search.id),
  }),
  component: DocumentsPage,
});

type Item = Schemas["VerificationQueueItem"];

function DocumentsPage() {
  const { status, id } = Route.useSearch();
  const navigate = Route.useNavigate();
  const list = usePagedList(["applications", status], async (limit, offset) => (await api.get("/v1/ops/verification/applications", { query: { status, limit, offset } })).data);

  return (
    <div className="flex flex-col gap-4 pb-28 md:pb-0">
      <PageHeader title="Driver documents" description="Check every document against the driver, then decide on the application." refreshing={list.isRefetching} onRefresh={() => list.refetch()} />
      <Filters filters={[{ key: "status", label: "Status", options: STATUSES, value: status, fallback: "under_review" }]} onApply={(v) => navigate({ search: { status: oneOf(v.status, STATUSES, "under_review") } })} />
      <RecordList<Item>
        query={list}
        rowKey={(r) => r.application.id}
        onOpen={(r) => navigate({ search: (prev) => ({ ...prev, id: r.application.id }) })}
        empty={EMPTY[status] ?? "No applications in this state."}
        columns={[
          { header: "Driver", cell: (r) => <span className="font-medium">{r.full_name || "Name not given"}</span> },
          { header: "Phone", cell: (r) => <span className="tnum">{r.phone_masked}</span> },
          { header: "Plate", cell: (r) => <span className="font-mono text-meta">{r.plate_number || "—"}</span> },
          { header: "Application", cell: (r) => <StatusBadge status={r.application.status} /> },
          { header: "Driver status", cell: (r) => label(r.driver_status) },
          { header: "Submitted", cell: (r) => <span className="text-muted-foreground">{when(r.application.created_at)}</span> },
        ]}
        card={(r) => ({
          title: r.full_name || "Name not given",
          status: <StatusBadge status={r.application.status} />,
          tags: [r.plate_number ? <span key="plate" className="font-mono text-meta">{r.plate_number}</span> : null, <span key="phone" className="tnum">{r.phone_masked}</span>],
          meta: [`Driver ${label(r.driver_status).toLowerCase()}`, `Submitted ${when(r.application.created_at)}`],
        })}
      />
      <ApplicationSheet id={id} onClose={() => navigate({ search: (prev) => ({ ...prev, id: undefined }) })} />
    </div>
  );
}
