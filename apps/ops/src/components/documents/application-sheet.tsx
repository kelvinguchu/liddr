import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { EyeIcon } from "lucide-react";
import { toast } from "sonner";
import { DetailRows, DetailSection, DetailSheet, DetailStats, Mono } from "@/components/detail-sheet";
import { DocumentViewer } from "@/components/documents/document-viewer";
import { ApplicationDecisionDialog, DocumentDecisionDialog, docName, ORDER, type ApplicationDecision, type DocumentDecision } from "@/components/documents/decisions";
import { StatusBadge } from "@/components/status-badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { api, problemText, type Schemas } from "@/lib/api";
import { day, label, when } from "@/lib/format";
import { StepUpCancelled } from "@/lib/step-up";

type Doc = Schemas["ReviewableDocument"];

const OPEN = ["pending", "under_review", "resubmission_required"];

/** One driver's application: every document, and the decisions on it. */
export function ApplicationSheet({ id, onClose }: { id?: string; onClose: () => void }) {
  const queryClient = useQueryClient();
  const detail = useQuery({
    queryKey: ["application", id],
    enabled: Boolean(id),
    queryFn: () => api.get("/v1/ops/verification/applications/{application_id}", { path: { application_id: id ?? "" } }),
  });
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [viewing, setViewing] = useState<Doc | null>(null);
  const [docDecision, setDocDecision] = useState<{ doc: Doc; decision: DocumentDecision } | null>(null);
  const [appDecision, setAppDecision] = useState<ApplicationDecision | null>(null);

  const changed = async () => {
    setChosen(new Set());
    await Promise.all([queryClient.invalidateQueries({ queryKey: ["application", id] }), queryClient.invalidateQueries({ queryKey: ["applications"] })]);
  };

  const bulk = useMutation({
    mutationFn: () => api.post("/v1/ops/verification/documents/reviews/bulk", { body: { document_ids: [...chosen], decision: "approve" } }),
    onSuccess: async (res) => {
      const failed = res.data.filter((r) => !r.ok);
      const count = (n: number) => `${n} document${n === 1 ? "" : "s"}`;
      if (failed.length) toast.error(`${count(res.data.length - failed.length)} approved, ${failed.length} not (${label(failed[0].code)})`);
      else toast.success(`${count(res.data.length)} approved`);
      await changed();
    },
    onError: (err) => !(err instanceof StepUpCancelled) && toast.error(problemText(err)),
  });

  const app = detail.data;
  const s = app?.summary;
  const isOpen = s ? OPEN.includes(s.application.status) : false;
  const docs = [...(app?.documents ?? [])].sort((a, b) => ORDER.indexOf(a.document.document_type) - ORDER.indexOf(b.document.document_type));
  const reviewable = (d: Doc) => isOpen && d.document.status === "pending_review" && d.scan_status === "clean";
  const validated = docs.filter((d) => d.document.status === "validated").length;
  const waiting = docs.filter(reviewable).length;
  const toggle = (docID: string, on: boolean) =>
    setChosen((prev) => {
      const next = new Set(prev);
      if (on) next.add(docID);
      else next.delete(docID);
      return next;
    });

  return (
    <>
      <DetailSheet
        open={Boolean(id)}
        onClose={onClose}
        eyebrow="Driver application"
        title={s ? s.full_name || "Name not given" : undefined}
        subtitle={s ? [s.plate_number, s.phone_masked, `submitted ${when(s.application.created_at)}`].filter(Boolean).join(" · ") : undefined}
        error={detail.error}
        onRetry={() => detail.refetch()}
        actions={
          isOpen ? (
            <>
              <Button onClick={() => setAppDecision("approve")}>Approve driver</Button>
              <Button variant="outline" onClick={() => setAppDecision("request_resubmission")}>
                Ask for resubmission
              </Button>
              <Button variant="outline" className="text-destructive" onClick={() => setAppDecision("reject")}>
                Reject
              </Button>
              <Button variant="ghost" className="text-destructive" onClick={() => setAppDecision("suspend")}>
                Suspend
              </Button>
            </>
          ) : undefined
        }
      >
        {s ? (
          <>
            <DetailStats
              items={[
                { label: "Application", value: <StatusBadge status={s.application.status} /> },
                { label: "Validated", value: `${validated} of ${docs.length}` },
                { label: "Awaiting you", value: String(waiting), tone: waiting > 0 ? "brand" : undefined },
                { label: "Driver status", value: label(s.driver_status) },
              ]}
            />
            {!isOpen ? (
              <p className="text-cell text-muted-foreground">
                Decided {when(s.application.decided_at)}
                {s.application.decision_reason ? `: ${s.application.decision_reason}` : "."}
              </p>
            ) : null}
            <DetailSection
              title="Documents"
              action={
                isOpen && waiting > 0 ? (
                  <Button size="sm" disabled={chosen.size === 0 || bulk.isPending} onClick={() => bulk.mutate()}>
                    {chosen.size ? `Approve selected (${chosen.size})` : "Approve selected"}
                  </Button>
                ) : undefined
              }
            >
              {docs.length === 0 ? (
                <p className="rounded-xl border py-10 text-center text-cell text-muted-foreground">The driver has not uploaded anything yet.</p>
              ) : (
                <ul className="divide-y rounded-xl border">
                  {docs.map((d) => {
                    const can = reviewable(d);
                    const name = docName(d.document.document_type);
                    return (
                      <li key={d.document.id} className="flex items-start gap-3 px-3.5 py-3">
                        <span className="mt-0.5 w-4 shrink-0">{can ? <Checkbox aria-label={`Select ${name}`} checked={chosen.has(d.document.id)} onCheckedChange={(on) => toggle(d.document.id, on === true)} /> : null}</span>
                        <div className="flex min-w-0 flex-1 flex-col gap-1">
                          <div className="flex items-start justify-between gap-2">
                            <span className="font-medium">{name}</span>
                            <span className="flex flex-wrap justify-end gap-1.5">
                              <StatusBadge status={d.document.status} />
                              {d.scan_status !== "clean" ? <StatusBadge status={d.scan_status} text={`Scan ${label(d.scan_status).toLowerCase()}`} /> : null}
                            </span>
                          </div>
                          <span className="text-meta text-muted-foreground">
                            {[`Version ${d.document.version}`, `uploaded ${when(d.document.created_at)}`, d.document.expires_on && `expires ${day(d.document.expires_on)}`].filter(Boolean).join(" · ")}
                          </span>
                          {d.document.rejection_reason ? <span className="text-meta text-muted-foreground">Reason: {d.document.rejection_reason}</span> : null}
                          <div className="mt-1.5 grid grid-cols-2 gap-2 sm:flex sm:flex-wrap">
                            <Button variant="outline" size="sm" disabled={d.scan_status !== "clean"} title={d.scan_status !== "clean" ? "Only files that passed the virus scan can be opened" : undefined} onClick={() => setViewing(d)}>
                              <EyeIcon />
                              View
                            </Button>
                            {can ? (
                              <>
                                <Button variant="outline" size="sm" onClick={() => setDocDecision({ doc: d, decision: "approve" })}>
                                  Approve
                                </Button>
                                <Button variant="outline" size="sm" className="text-destructive" onClick={() => setDocDecision({ doc: d, decision: "reject" })}>
                                  Reject
                                </Button>
                                <Button variant="ghost" size="sm" onClick={() => setDocDecision({ doc: d, decision: "request_resubmission" })}>
                                  Ask again
                                </Button>
                              </>
                            ) : null}
                          </div>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </DetailSection>
            <DetailSection title="Driver">
              <DetailRows
                rows={[
                  ["Driver ID", <Mono key="id">{s.driver_id}</Mono>],
                  ["Phone", s.phone_masked],
                  ["Plate", s.plate_number],
                ]}
              />
            </DetailSection>
          </>
        ) : null}
      </DetailSheet>

      <DocumentViewer
        doc={viewing}
        canDecide={viewing ? reviewable(viewing) : false}
        onClose={() => setViewing(null)}
        onDecide={(decision) => {
          if (viewing) setDocDecision({ doc: viewing, decision });
          setViewing(null);
        }}
      />
      <DocumentDecisionDialog value={docDecision} onClose={() => setDocDecision(null)} onDone={changed} />
      <ApplicationDecisionDialog applicationID={id} decision={appDecision} onClose={() => setAppDecision(null)} onDone={changed} />
    </>
  );
}
