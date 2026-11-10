import { useState, type FormEvent } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { RefreshCwIcon, SearchIcon } from "lucide-react";
import { toast } from "sonner";
import { DetailRows, DetailSection, DetailStats, Mono } from "@/components/detail-sheet";
import { NativeSelect } from "@/components/action-dialog";
import { PageHeader } from "@/components/page-header";
import { Records } from "@/components/record-list";
import { StatusBadge } from "@/components/status-badge";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { api, ApiError, problemText, type Schemas } from "@/lib/api";
import { isUUID, kes, label, when } from "@/lib/format";
import { StepUpCancelled } from "@/lib/step-up";

export const Route = createFileRoute("/payments")({ component: PaymentsPage });

type Kind = "driver" | "checkout";
const KINDS: readonly (readonly [Kind, string])[] = [
  ["driver", "Driver account ID"],
  ["checkout", "M-Pesa checkout request ID"],
];
const PLACEHOLDER: Record<Kind, string> = { driver: "e.g. 8d03619a-027f-441b-…", checkout: "e.g. ws_CO_10112026…" };
const STATES: Record<string, string> = {
  initiated: "Starting",
  pending_callback: "Waiting for M-Pesa",
  success: "Paid",
  failed: "Failed",
  cancelled: "Cancelled by driver",
  timeout: "Timed out",
  needs_review: "Needs review",
};
const stateText = (s: string) => STATES[s] ?? label(s);
const by = (channel: string) => (channel === "stk" ? "Phone prompt" : "Paybill");

// Look up a driver's weekly subscription or one M-Pesa payment, and ask M-Pesa
// again about a payment that never settled.
function PaymentsPage() {
  const [kind, setKind] = useState<Kind>("driver");
  const [value, setValue] = useState("");
  const [lookup, setLookup] = useState<{ kind: Kind; id: string } | null>(null);
  const [invalid, setInvalid] = useState("");

  function submit(event: FormEvent) {
    event.preventDefault();
    const id = value.trim();
    if (kind === "driver" && !isUUID(id)) {
      setInvalid("Enter the full driver account ID.");
      return;
    }
    setInvalid("");
    setLookup({ kind, id });
  }

  return (
    <div className="flex flex-col gap-4">
      <PageHeader title="Payments" description="Driver subscriptions and M-Pesa payments. A recheck asks M-Pesa directly and can activate a driver who paid." />
      <form onSubmit={submit} className="flex flex-col gap-2.5 md:flex-row md:items-center md:gap-3">
        <div className="md:w-64">
          <NativeSelect name="kind" value={kind} onChange={(v) => setKind(v as Kind)} options={KINDS} />
        </div>
        <div className="relative md:w-[28rem]">
          <SearchIcon className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input required aria-label="ID to look up" spellCheck={false} autoComplete="off" placeholder={PLACEHOLDER[kind]} value={value} onChange={(e) => setValue(e.target.value)} className="h-10 pl-9 font-mono text-cell md:h-9" />
        </div>
        <Button type="submit" className="h-10 md:h-8">
          Look up
        </Button>
      </form>
      {invalid ? <p className="text-cell font-medium text-destructive">{invalid}</p> : null}
      {!lookup ? (
        <Empty className="py-16">
          <EmptyHeader>
            <EmptyTitle>Nothing looked up yet</EmptyTitle>
            <EmptyDescription>Look up a driver or a payment to see it here.</EmptyDescription>
          </EmptyHeader>
        </Empty>
      ) : lookup.kind === "driver" ? (
        <DriverResult id={lookup.id} />
      ) : (
        <PaymentResult checkoutID={lookup.id} />
      )}
    </div>
  );
}

function Loading() {
  return (
    <div className="flex flex-col gap-3" role="status" aria-label="Loading">
      <Skeleton className="h-20 w-full" />
      <Skeleton className="h-40 w-full" />
    </div>
  );
}

function Failed({ error, notFound }: { error: unknown; notFound: string }) {
  if (error instanceof ApiError && error.status === 404) {
    return (
      <Empty className="py-16">
        <EmptyHeader>
          <EmptyTitle>Not found</EmptyTitle>
          <EmptyDescription>{notFound}</EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }
  return (
    <Alert variant="destructive">
      <AlertDescription>{problemText(error)}</AlertDescription>
    </Alert>
  );
}

function DriverResult({ id }: { id: string }) {
  const driver = useQuery({ queryKey: ["driver-subscription", id], queryFn: () => api.get("/v1/ops/subscriptions/drivers/{user_id}", { path: { user_id: id } }) });
  if (driver.isPending) return <Loading />;
  if (driver.isError) return <Failed error={driver.error} notFound="No driver has that account ID." />;
  const d = driver.data;
  return (
    <div className="flex flex-col gap-5">
      <DetailStats
        items={[
          { label: "This week", value: <StatusBadge status={d.status} />, tone: "brand" },
          { label: "Weekly amount", value: kes(d.amount_kes) },
          { label: "Account reference", value: <Mono>{d.reference}</Mono> },
        ]}
      />
      <DetailSection title="Payment attempts">
        {d.payments.length === 0 ? (
          <p className="rounded-xl border py-10 text-center text-cell text-muted-foreground">This driver has not tried to pay yet.</p>
        ) : (
          <Records<Schemas["SubscriptionPayment"]>
            rows={d.payments}
            rowKey={(p) => p.id}
            columns={[
              { header: "Requested", cell: (p) => <span className="text-muted-foreground">{when(p.requested_at)}</span> },
              { header: "Amount", className: "text-right", cell: (p) => <span className="font-medium tnum">{kes(p.amount_kes)}</span> },
              { header: "By", cell: (p) => by(p.channel) },
              { header: "Receipt", cell: (p) => (p.receipt ? <Mono>{p.receipt}</Mono> : "—") },
              { header: "Paid", cell: (p) => <span className="text-muted-foreground">{when(p.paid_at)}</span> },
              { header: "Status", cell: (p) => <StatusBadge status={p.status} text={stateText(p.status)} /> },
            ]}
            card={(p) => ({
              title: <span className="tnum">{kes(p.amount_kes)}</span>,
              status: <StatusBadge status={p.status} text={stateText(p.status)} />,
              tags: [<span key="b">{by(p.channel)}</span>, p.receipt ? <Mono key="r">{p.receipt}</Mono> : null],
              meta: [`Requested ${when(p.requested_at)}`, p.paid_at ? `Paid ${when(p.paid_at)}` : null],
            })}
          />
        )}
      </DetailSection>
    </div>
  );
}

function PaymentResult({ checkoutID }: { checkoutID: string }) {
  const queryClient = useQueryClient();
  const key = ["payment", checkoutID];
  const payment = useQuery({ queryKey: key, queryFn: () => api.get("/v1/ops/subscriptions/payments/{checkout_request_id}", { path: { checkout_request_id: checkoutID } }) });
  const recheck = useMutation({
    mutationFn: () => api.post("/v1/ops/subscriptions/payments/{checkout_request_id}/recheck", { path: { checkout_request_id: checkoutID } }),
    onSuccess: (fresh: Schemas["PaymentDetail"]) => {
      const before = payment.data?.status;
      toast.success(fresh.status === before ? `No change. Still: ${stateText(fresh.status)}` : `Updated to: ${stateText(fresh.status)}`);
      queryClient.setQueryData(key, fresh);
    },
    onError: (err) => !(err instanceof StepUpCancelled) && toast.error(problemText(err)),
  });
  if (payment.isPending) return <Loading />;
  if (payment.isError) return <Failed error={payment.error} notFound="No payment has that checkout request ID." />;
  const p = payment.data;
  return (
    <div className="flex flex-col gap-5">
      <DetailStats
        items={[
          { label: "Amount", value: kes(p.amount_kes) },
          { label: "Status", value: <StatusBadge status={p.status} text={stateText(p.status)} />, tone: p.status === "success" ? undefined : "brand" },
          { label: "By", value: by(p.channel) },
          { label: "Receipt", value: p.receipt ? <Mono>{p.receipt}</Mono> : "—" },
        ]}
      />
      {p.status === "success" ? (
        <p className="text-cell text-muted-foreground">M-Pesa confirmed this payment. There is nothing to recheck.</p>
      ) : (
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
          <Button variant="outline" className="h-10 sm:h-8" disabled={recheck.isPending} onClick={() => recheck.mutate()}>
            <RefreshCwIcon className={recheck.isPending ? "animate-spin" : undefined} />
            Ask M-Pesa again
          </Button>
          <span className="text-meta text-muted-foreground">Use this when a driver paid but still shows as unpaid.</span>
        </div>
      )}
      <DetailSection title="Payment">
        <DetailRows
          rows={[
            ["Driver account", <Mono key="d">{p.driver_id}</Mono>],
            ["Phone", p.phone_masked],
            ["Checkout request", <Mono key="c">{checkoutID}</Mono>],
            ["Requested", when(p.requested_at)],
            ["Paid", when(p.paid_at)],
          ]}
        />
      </DetailSection>
    </div>
  );
}
