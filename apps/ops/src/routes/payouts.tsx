import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { Filters } from "@/components/filters";
import { CancelPayoutDialog, CHANNEL_NAMES, MarkPaidDialog } from "@/components/money/payout-dialogs";
import { PageHeader } from "@/components/page-header";
import { RecordList, type Column } from "@/components/record-list";
import { StatusBadge } from "@/components/status-badge";
import { Button } from "@/components/ui/button";
import { api, type Schemas } from "@/lib/api";
import { kes, label, shortID, when } from "@/lib/format";
import { usePagedList } from "@/lib/lists";
import { oneOf, type Options, type SearchIn } from "@/lib/search";

type Status = "approved" | "paid" | "cancelled";
type Payout = Schemas["Compensation"];

const STATUSES: Options<Status> = [
  ["approved", "To pay"],
  ["paid", "Paid"],
  ["cancelled", "Cancelled"],
];

export const Route = createFileRoute("/payouts")({
  validateSearch: (search: SearchIn<{ status: Status }>): { status: Status } => ({ status: oneOf(search.status, STATUSES, "approved") }),
  component: PayoutsPage,
});

const channel = (c?: string) => (c ? (CHANNEL_NAMES[c] ?? label(c)) : "—");

// Refunds and credits awarded in dispute rulings, until someone pays them.
function PayoutsPage() {
  const { status } = Route.useSearch();
  const navigate = Route.useNavigate();
  const queryClient = useQueryClient();
  const list = usePagedList(["payouts", status], async (limit, offset) => (await api.get("/v1/ops/disputes/compensations", { query: { status, limit, offset } })).data);
  const [paying, setPaying] = useState<Payout | null>(null);
  const [cancelling, setCancelling] = useState<Payout | null>(null);
  const changed = () => queryClient.invalidateQueries({ queryKey: ["payouts"] });
  const settle = (p: Payout) =>
    p.status === "approved" ? (
      <>
        <Button size="sm" onClick={() => setPaying(p)}>
          Mark paid
        </Button>
        <Button variant="outline" size="sm" className="text-destructive" onClick={() => setCancelling(p)}>
          Cancel
        </Button>
      </>
    ) : null;
  const paid = status === "paid";
  const columns: Column<Payout>[] = [
    { header: "Amount", className: "text-right", cell: (p) => <span className="font-medium tnum">{kes(p.amount_kes)}</span> },
    { header: "Type", cell: (p) => label(p.compensation_type) },
    { header: "To account", cell: (p) => <span className="font-mono text-meta" title={p.beneficiary_id}>{shortID(p.beneficiary_id)}</span> },
    ...(paid
      ? [
          { header: "Paid", cell: (p: Payout) => <span className="text-muted-foreground">{when(p.processed_at)}</span> },
          { header: "Paid by", cell: (p: Payout) => channel(p.processing_channel) },
          { header: "Reference", cell: (p: Payout) => <span className="font-mono text-meta">{p.processing_reference || "—"}</span> },
        ]
      : [
          { header: "Ride", cell: (p: Payout) => <span className="font-mono text-meta" title={p.ride_id}>{shortID(p.ride_id)}</span> },
          { header: "Awarded", cell: (p: Payout) => <span className="text-muted-foreground">{when(p.created_at)}</span> },
          { header: "Status", cell: (p: Payout) => <StatusBadge status={p.status} text={p.status === "approved" ? "To pay" : undefined} tone={p.status === "approved" ? "warn" : undefined} /> },
          { header: "", className: "w-px", cell: (p: Payout) => <div className="flex justify-end gap-2">{settle(p)}</div> },
        ]),
  ];

  return (
    <div className="flex flex-col gap-4 pb-28 md:pb-0">
      <PageHeader title="Payouts" description="Send the money first, then record how it was paid and the reference." refreshing={list.isRefetching} onRefresh={() => list.refetch()} />
      <Filters filters={[{ key: "status", label: "Status", options: STATUSES, value: status, fallback: "approved" }]} onApply={(v) => navigate({ search: { status: oneOf(v.status, STATUSES, "approved") } })} />
      <RecordList<Payout>
        query={list}
        rowKey={(p) => p.id}
        empty={status === "approved" ? "Nothing waiting to be paid." : `No ${label(status).toLowerCase()} payouts.`}
        columns={columns}
        card={(p) => ({
          title: <span className="tnum">{kes(p.amount_kes)}</span>,
          status: <StatusBadge status={p.status} text={p.status === "approved" ? "To pay" : undefined} tone={p.status === "approved" ? "warn" : undefined} />,
          tags: [<span key="t">{label(p.compensation_type)}</span>, <span key="b">To <span className="font-mono">{shortID(p.beneficiary_id)}</span></span>],
          meta: paid
            ? [`Paid ${when(p.processed_at)}`, channel(p.processing_channel), p.processing_reference ? <span key="r" className="font-mono">{p.processing_reference}</span> : null]
            : [`Awarded ${when(p.created_at)}`, <span key="r">Ride <span className="font-mono">{shortID(p.ride_id)}</span></span>],
          actions: settle(p),
        })}
      />
      <MarkPaidDialog payout={paying} onClose={() => setPaying(null)} onDone={changed} />
      <CancelPayoutDialog payout={cancelling} onClose={() => setCancelling(null)} onDone={changed} />
    </div>
  );
}
