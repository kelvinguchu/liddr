import { useEffect, useState } from "react";
import { ActionDialog, FormField, NativeSelect } from "@/components/action-dialog";
import { Input } from "@/components/ui/input";
import { api, type Schemas } from "@/lib/api";
import { kes } from "@/lib/format";

type Channel = Schemas["MarkPaidRequest"]["channel"];

export const CHANNEL_NAMES: Record<string, string> = {
  mpesa_reversal: "M-Pesa reversal",
  wallet_credit: "Wallet credit",
  bank_transfer: "Bank transfer",
  manual_ops: "Other, by hand",
};
const CHANNELS = Object.entries(CHANNEL_NAMES) as [Channel, string][];

export function MarkPaidDialog({ payout, onClose, onDone }: { payout: Schemas["Compensation"] | null; onClose: () => void; onDone: () => Promise<unknown> }) {
  const [channel, setChannel] = useState<Channel>("mpesa_reversal");
  const [reference, setReference] = useState("");
  useEffect(() => {
    if (payout) setReference("");
  }, [payout]);
  return (
    <ActionDialog
      open={payout !== null}
      onOpenChange={(open) => !open && onClose()}
      title={payout ? `Record ${kes(payout.amount_kes)} as paid` : "Record as paid"}
      description="Only record this once the money has actually gone out."
      submitLabel="Mark paid"
      done="Recorded as paid"
      onSubmit={async () => {
        if (!payout) return;
        await api.post("/v1/ops/disputes/compensations/{compensation_id}/mark-paid", { path: { compensation_id: payout.id }, body: { channel, reference: reference.trim() } });
        await onDone();
      }}
    >
      <FormField label="Paid by">
        <NativeSelect name="channel" value={channel} onChange={(v) => setChannel(v as Channel)} options={CHANNELS} />
      </FormField>
      <FormField label="Reference">
        <Input required maxLength={200} spellCheck={false} placeholder="e.g. the M-Pesa receipt number" value={reference} onChange={(e) => setReference(e.target.value)} />
      </FormField>
    </ActionDialog>
  );
}

export function CancelPayoutDialog({ payout, onClose, onDone }: { payout: Schemas["Compensation"] | null; onClose: () => void; onDone: () => Promise<unknown> }) {
  return (
    <ActionDialog
      open={payout !== null}
      onOpenChange={(open) => !open && onClose()}
      title="Cancel this payout?"
      description={payout ? `${kes(payout.amount_kes)} will not be paid. This cannot be undone.` : undefined}
      submitLabel="Cancel payout"
      destructive
      done="Payout cancelled"
      onSubmit={async () => {
        if (!payout) return;
        await api.post("/v1/ops/disputes/compensations/{compensation_id}/cancel", { path: { compensation_id: payout.id } });
        await onDone();
      }}
    />
  );
}
