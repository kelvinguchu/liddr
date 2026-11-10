import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { BanIcon } from "lucide-react";
import { toast } from "sonner";
import { ActionDialog, FormField, NativeSelect } from "@/components/action-dialog";
import { DetailRows, DetailSection, DetailSheet, DetailStats, Mono } from "@/components/detail-sheet";
import { SeverityBadge, StatusBadge } from "@/components/status-badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { api, problemText, type Schemas } from "@/lib/api";
import { label, nairobiFuture, when } from "@/lib/format";

type Decision = Schemas["ReportReviewRequest"]["decision"];

const DECISIONS: readonly (readonly [Decision, string])[] = [
  ["no_action", "No action"],
  ["warning", "Warning"],
  ["temporary_suspension", "Temporary suspension"],
  ["permanent_ban", "Permanent ban"],
  ["needs_more_info", "Needs more information"],
  ["escalate", "Escalate"],
  ["dismiss", "Dismiss"],
];

/** One report: what was said, who it is about, and the decision on it. */
export function ReportSheet({ id, onClose }: { id?: string; onClose: () => void }) {
  const queryClient = useQueryClient();
  const detail = useQuery({
    queryKey: ["report", id],
    enabled: Boolean(id),
    queryFn: () => api.get("/v1/ops/moderation/reports/{report_id}", { path: { report_id: id ?? "" } }),
  });
  const [deciding, setDeciding] = useState(false);
  const changed = () => Promise.all([queryClient.invalidateQueries({ queryKey: ["report", id] }), queryClient.invalidateQueries({ queryKey: ["reports"] })]);
  const triage = useMutation({
    mutationFn: (to: "triaged" | "under_review") => api.post("/v1/ops/moderation/reports/{report_id}/triage", { path: { report_id: id ?? "" }, body: { status: to } }),
    onSuccess: async (_, to) => {
      toast.success(to === "under_review" ? "Review started" : "Marked triaged");
      await changed();
    },
    onError: (err) => toast.error(problemText(err)),
  });

  const r = detail.data;
  const s = r?.summary;
  const closed = s?.status === "resolved" || s?.status === "dismissed";

  return (
    <>
      <DetailSheet
        open={Boolean(id)}
        onClose={onClose}
        eyebrow="Report"
        title={s ? label(s.category) : undefined}
        subtitle={s ? `${label(s.incident_type)} · received ${when(s.created_at)}` : undefined}
        error={detail.error}
        onRetry={() => detail.refetch()}
        actions={
          s && !closed ? (
            <>
              {s.status !== "under_review" ? (
                <Button disabled={triage.isPending} onClick={() => triage.mutate("under_review")}>
                  Start review
                </Button>
              ) : null}
              {s.status === "submitted" ? (
                <Button variant="outline" disabled={triage.isPending} onClick={() => triage.mutate("triaged")}>
                  Mark triaged
                </Button>
              ) : null}
              <Button variant={s.status === "under_review" ? "default" : "outline"} onClick={() => setDeciding(true)}>
                Decide
              </Button>
            </>
          ) : undefined
        }
      >
        {r && s ? (
          <>
            <DetailStats
              items={[
                { label: "Severity", value: <SeverityBadge level={s.severity} /> },
                { label: "Status", value: <StatusBadge status={s.status} /> },
                { label: "Source", value: label(s.source) },
                { label: "Outcome", value: r.outcome ? label(r.outcome) : "—" },
              ]}
            />
            <DetailSection title="What was reported">
              <div className="rounded-xl border px-4 py-3.5 text-body leading-relaxed break-words whitespace-pre-wrap">{r.description || "No description was given."}</div>
              <p className="text-meta text-muted-foreground">The reporter's own words. Never share them, or who sent them, with the reported person.</p>
            </DetailSection>
            <DetailSection title="People and ride">
              <DetailRows
                rows={[
                  ["Reported account", <Mono key="a">{s.reported_id}</Mono>],
                  ["Reported by", s.reporter_id ? <Mono key="b">{s.reporter_id}</Mono> : "System"],
                  ["Ride", s.ride_id ? <Mono key="c">{s.ride_id}</Mono> : "Not linked to a ride"],
                ]}
              />
            </DetailSection>
            <Button variant="outline" size="sm" className="self-start" asChild>
              <Link to="/penalties" search={{ user: s.reported_id }}>
                <BanIcon />
                Penalties on this account
              </Link>
            </Button>
          </>
        ) : null}
      </DetailSheet>
      <DecideDialog id={id} open={deciding} onOpenChange={setDeciding} onDone={changed} />
    </>
  );
}

function DecideDialog({ id, open, onOpenChange, onDone }: { id?: string; open: boolean; onOpenChange: (open: boolean) => void; onDone: () => Promise<unknown> }) {
  const [decision, setDecision] = useState<Decision>("no_action");
  const [reasonCode, setReasonCode] = useState("");
  const [notes, setNotes] = useState("");
  const [endsAt, setEndsAt] = useState("");
  const suspends = decision === "temporary_suspension";
  return (
    <ActionDialog
      open={open}
      onOpenChange={onOpenChange}
      title="Decide this report"
      description="Penalties apply straight away and are recorded against your account."
      submitLabel="Record decision"
      done="Decision recorded"
      onSubmit={async () => {
        await api.post("/v1/ops/moderation/reports/{report_id}/review", {
          path: { report_id: id ?? "" },
          body: { decision, reason_code: reasonCode.trim() || undefined, notes: notes.trim() || undefined, ends_at: suspends ? nairobiFuture(endsAt) : undefined },
        });
        setReasonCode("");
        setNotes("");
        setEndsAt("");
        await onDone();
      }}
    >
      <FormField label="Decision">
        <NativeSelect name="decision" value={decision} onChange={(v) => setDecision(v as Decision)} options={DECISIONS} />
      </FormField>
      <FormField label="Reason code" hint="Short and consistent, so penalties can be counted.">
        <Input maxLength={100} placeholder="e.g. unsafe_driving" value={reasonCode} onChange={(e) => setReasonCode(e.target.value)} />
      </FormField>
      {suspends ? (
        <FormField label="Suspended until" hint="Nairobi time.">
          <Input required type="datetime-local" value={endsAt} onChange={(e) => setEndsAt(e.target.value)} />
        </FormField>
      ) : null}
      <FormField label="Notes" hint="Internal. Up to 1000 characters.">
        <Textarea maxLength={1000} value={notes} onChange={(e) => setNotes(e.target.value)} />
      </FormField>
    </ActionDialog>
  );
}
