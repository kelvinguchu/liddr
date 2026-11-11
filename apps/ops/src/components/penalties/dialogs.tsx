import { useEffect, useState } from "react";
import { ActionDialog, FormField, NativeSelect } from "@/components/action-dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { api, type Schemas } from "@/lib/api";
import { isUUID, label, nairobiFuture, shortID } from "@/lib/format";

type Action = Schemas["EnforcementRequest"]["action"];
type Scope = NonNullable<Schemas["EnforcementRequest"]["scope"]>;

const ACTIONS: readonly (readonly [Action, string])[] = [
  ["warning", "Warning"],
  ["feature_restriction", "Feature restriction"],
  ["temporary_suspension", "Temporary suspension"],
  ["permanent_ban", "Permanent ban"],
];
const SCOPES: readonly (readonly [Scope, string])[] = [
  ["platform", "Everything"],
  ["communication", "In-ride chat only"],
];

/** A penalty with no report behind it. Deciding a report is preferred. */
export function ApplyPenaltyDialog({ open, onOpenChange, account, onDone }: { open: boolean; onOpenChange: (open: boolean) => void; account?: string; onDone: () => Promise<unknown> }) {
  const [userID, setUserID] = useState(account ?? "");
  const [action, setAction] = useState<Action>("warning");
  const [scope, setScope] = useState<Scope>("platform");
  const [reasonCode, setReasonCode] = useState("");
  const [details, setDetails] = useState("");
  const [endsAt, setEndsAt] = useState("");
  useEffect(() => {
    if (open) setUserID(account ?? "");
  }, [open, account]);
  const hasEnd = action === "temporary_suspension" || action === "feature_restriction";

  return (
    <ActionDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Apply a penalty"
      description="Prefer deciding a report, which ties the penalty to its evidence. Use this when there is no report."
      submitLabel="Apply penalty"
      destructive
      done="Penalty applied"
      onSubmit={async () => {
        if (!isUUID(userID)) throw new Error("Enter the full account ID.");
        await api.post("/v1/ops/moderation/enforcements", {
          body: {
            user_id: userID.trim(),
            action,
            scope,
            reason_code: reasonCode.trim(),
            reason_text: details.trim() || undefined,
            ends_at: hasEnd && (endsAt || action === "temporary_suspension") ? nairobiFuture(endsAt) : undefined,
          },
        });
        setReasonCode("");
        setDetails("");
        setEndsAt("");
        await onDone();
      }}
    >
      <FormField label="Account ID">
        <Input required spellCheck={false} placeholder="Full account ID" className="font-mono text-cell" value={userID} onChange={(e) => setUserID(e.target.value)} />
      </FormField>
      <div className="grid gap-4 sm:grid-cols-2">
        <FormField label="Penalty">
          <NativeSelect name="action" value={action} onChange={(v) => setAction(v as Action)} options={ACTIONS} />
        </FormField>
        <FormField label="Applies to">
          <NativeSelect name="scope" value={scope} onChange={(v) => setScope(v as Scope)} options={SCOPES} />
        </FormField>
      </div>
      <FormField label="Reason code">
        <Input required maxLength={100} placeholder="e.g. harassment" value={reasonCode} onChange={(e) => setReasonCode(e.target.value)} />
      </FormField>
      {hasEnd ? (
        <FormField label="Until" hint={action === "temporary_suspension" ? "Nairobi time." : "Nairobi time. Leave empty for a restriction with no end."}>
          <Input required={action === "temporary_suspension"} type="datetime-local" value={endsAt} onChange={(e) => setEndsAt(e.target.value)} />
        </FormField>
      ) : null}
      <FormField label="Details" hint="Internal. Up to 1000 characters.">
        <Textarea maxLength={1000} value={details} onChange={(e) => setDetails(e.target.value)} />
      </FormField>
    </ActionDialog>
  );
}

export function LiftPenaltyDialog({ penalty, onClose, onDone }: { penalty: Schemas["Enforcement"] | null; onClose: () => void; onDone: () => Promise<unknown> }) {
  return (
    <ActionDialog
      open={penalty !== null}
      onOpenChange={(open) => !open && onClose()}
      title="Lift this penalty?"
      description={penalty ? `${label(penalty.action)} on account ${shortID(penalty.user_id)} ends now.` : undefined}
      submitLabel="Lift penalty"
      done="Penalty lifted"
      onSubmit={async () => {
        if (!penalty) return;
        await api.post("/v1/ops/moderation/enforcements/{enforcement_id}/lift", { path: { enforcement_id: penalty.id } });
        await onDone();
      }}
    />
  );
}
