import { useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { DetailRows, DetailSection, DetailSheet, DetailStats, Mono } from "@/components/detail-sheet";
import { Filters } from "@/components/filters";
import { RuleDialog } from "@/components/money/rule-dialog";
import { PageHeader } from "@/components/page-header";
import { RecordList } from "@/components/record-list";
import { SeverityBadge, StatusBadge } from "@/components/status-badge";
import { Button } from "@/components/ui/button";
import { api, type Schemas } from "@/lib/api";
import { label, shortID, when } from "@/lib/format";
import { usePagedList } from "@/lib/lists";
import { oneOf, optionalText, type Options, type SearchIn } from "@/lib/search";

type Status = "submitted" | "triaged" | "under_review" | "resolved" | "dismissed";
type Dispute = Schemas["DisputeCase"];

const STATUSES: Options<Status> = [
  ["submitted", "New"],
  ["triaged", "Triaged"],
  ["under_review", "Under review"],
  ["resolved", "Resolved"],
  ["dismissed", "Dismissed"],
];

export const Route = createFileRoute("/disputes")({
  validateSearch: (search: SearchIn<{ status: Status; id: string }>): { status: Status; id?: string } => ({
    status: oneOf(search.status, STATUSES, "submitted"),
    id: optionalText(search.id),
  }),
  component: DisputesPage,
});

function DisputesPage() {
  const { status, id } = Route.useSearch();
  const navigate = Route.useNavigate();
  const queryClient = useQueryClient();
  const list = usePagedList(["disputes", status], async (limit, offset) => (await api.get("/v1/ops/disputes", { query: { status, limit, offset } })).data);
  const [ruling, setRuling] = useState<Dispute | null>(null);
  // The API has no read for one dispute, so the sheet shows a loaded row.
  const open = id ? list.data?.pages.flat().find((d) => d.id === id) : undefined;
  const isOpen = open && open.status !== "resolved" && open.status !== "dismissed";
  const close = () => navigate({ search: (prev) => ({ ...prev, id: undefined }) });

  return (
    <div className="flex flex-col gap-4 pb-28 md:pb-0">
      <PageHeader title="Disputes" description="Refunds are capped at what the person was charged for the ride." refreshing={list.isRefetching} onRefresh={() => list.refetch()} />
      <Filters filters={[{ key: "status", label: "Status", options: STATUSES, value: status, fallback: "submitted" }]} onApply={(v) => navigate({ search: { status: oneOf(v.status, STATUSES, "submitted") } })} />
      <RecordList<Dispute>
        query={list}
        rowKey={(d) => d.id}
        onOpen={(d) => navigate({ search: (prev) => ({ ...prev, id: d.id }) })}
        empty={status === "submitted" ? "No new disputes." : "No disputes in this state."}
        columns={[
          { header: "Severity", cell: (d) => <SeverityBadge level={d.severity} /> },
          { header: "Type", cell: (d) => <span className="font-medium">{label(d.dispute_type)}</span> },
          { header: "Asks for", cell: (d) => (d.requested_resolution ? label(d.requested_resolution) : <span className="text-muted-foreground">Nothing specific</span>) },
          { header: "Ride", cell: (d) => <span className="font-mono text-meta" title={d.ride_id}>{shortID(d.ride_id)}</span> },
          { header: "Against", cell: (d) => <span className="font-mono text-meta" title={d.reported_id}>{shortID(d.reported_id)}</span> },
          { header: "Received", cell: (d) => <span className="text-muted-foreground">{when(d.created_at)}</span> },
          { header: "Status", cell: (d) => <StatusBadge status={d.status} /> },
        ]}
        card={(d) => ({
          title: label(d.dispute_type),
          status: <StatusBadge status={d.status} />,
          tags: [<SeverityBadge key="s" level={d.severity} />, <span key="a">{d.requested_resolution ? `Asks for ${label(d.requested_resolution).toLowerCase()}` : "Nothing specific asked for"}</span>],
          meta: [<span key="r">Ride <span className="font-mono">{shortID(d.ride_id)}</span></span>, <span key="g">Against <span className="font-mono">{shortID(d.reported_id)}</span></span>, when(d.created_at)],
        })}
      />
      <DetailSheet
        open={Boolean(id)}
        onClose={close}
        eyebrow="Dispute"
        title={open ? label(open.dispute_type) : undefined}
        subtitle={open ? `${label(open.incident_type)} · received ${when(open.created_at)}` : undefined}
        error={id && list.isSuccess && !open ? new Error("That dispute is not in this list. It may have moved to another status.") : undefined}
        actions={isOpen ? <Button onClick={() => setRuling(open)}>Rule on this</Button> : undefined}
      >
        {open ? (
          <>
            <DetailStats
              items={[
                { label: "Severity", value: <SeverityBadge level={open.severity} /> },
                { label: "Status", value: <StatusBadge status={open.status} /> },
                { label: "Asks for", value: open.requested_resolution ? label(open.requested_resolution) : "—" },
              ]}
            />
            <DetailSection title="What they said">
              <div className="rounded-xl border px-4 py-3.5 text-body leading-relaxed break-words whitespace-pre-wrap">{open.description}</div>
            </DetailSection>
            <DetailSection title="People and ride">
              <DetailRows
                rows={[
                  ["Raised by", open.reporter_id ? <Mono key="a">{open.reporter_id}</Mono> : "—"],
                  ["Against", <Mono key="b">{open.reported_id}</Mono>],
                  ["Ride", open.ride_id ? <Mono key="c">{open.ride_id}</Mono> : "—"],
                ]}
              />
            </DetailSection>
            <Button variant="outline" size="sm" className="self-start" asChild>
              <Link to="/payouts">See payouts</Link>
            </Button>
          </>
        ) : null}
      </DetailSheet>
      <RuleDialog
        dispute={ruling}
        onClose={() => setRuling(null)}
        onDone={async () => {
          close();
          await Promise.all([queryClient.invalidateQueries({ queryKey: ["disputes"] }), queryClient.invalidateQueries({ queryKey: ["payouts"] })]);
        }}
      />
    </div>
  );
}
