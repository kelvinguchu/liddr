import { useEffect, useState } from "react";
import { ActionDialog, FormField, NativeSelect } from "@/components/action-dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { api, type Schemas } from "@/lib/api";

type Outcome = Schemas["DisputeResolution"]["outcome"];

const OUTCOMES: readonly (readonly [Outcome, string])[] = [
  ["no_action", "No action"],
  ["refund_full", "Refund the full fare"],
  ["refund_partial", "Refund part of the fare"],
  ["credit_note", "Credit for a future ride"],
  ["escalate", "Escalate"],
  ["dismissed", "Dismiss"],
];

/** A ruling on a dispute. A refund or credit becomes a payout to settle. */
export function RuleDialog({ dispute, onClose, onDone }: { dispute: Schemas["DisputeCase"] | null; onClose: () => void; onDone: () => Promise<unknown> }) {
  const [outcome, setOutcome] = useState<Outcome>("no_action");
  const [amount, setAmount] = useState("");
  const [summary, setSummary] = useState("");
  useEffect(() => {
    if (!dispute) return;
    const asked = OUTCOMES.find(([v]) => v === dispute.requested_resolution);
    setOutcome(asked ? asked[0] : "no_action");
    setAmount("");
    setSummary("");
  }, [dispute]);
  const needsAmount = outcome === "refund_partial" || outcome === "credit_note";

  return (
    <ActionDialog
      open={dispute !== null}
      onOpenChange={(open) => !open && onClose()}
      title="Rule on this dispute"
      description="A refund or credit becomes a payout to settle under Payouts."
      submitLabel="Record ruling"
      done="Ruling recorded"
      onSubmit={async () => {
        if (!dispute) return;
        await api.post("/v1/ops/disputes/{report_id}/resolve", {
          path: { report_id: dispute.id },
          body: { outcome, amount_kes: needsAmount ? Number(amount) : undefined, summary: summary.trim() || undefined },
        });
        await onDone();
      }}
    >
      <FormField label="Outcome">
        <NativeSelect name="outcome" value={outcome} onChange={(v) => setOutcome(v as Outcome)} options={OUTCOMES} />
      </FormField>
      {needsAmount ? (
        <FormField label="Amount (KES)" hint="No more than the fare charged.">
          <Input required type="number" min={1} step={1} inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value)} />
        </FormField>
      ) : null}
      <FormField label="Summary" hint="Shared with both sides. Up to 1000 characters.">
        <Textarea maxLength={1000} value={summary} onChange={(e) => setSummary(e.target.value)} />
      </FormField>
    </ActionDialog>
  );
}
