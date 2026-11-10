import { useState } from "react";
import { ActionDialog, FormField } from "@/components/action-dialog";
import { Textarea } from "@/components/ui/textarea";
import { api, type Schemas } from "@/lib/api";
import { label } from "@/lib/format";

export type DocumentDecision = "approve" | "reject" | "request_resubmission";
export type ApplicationDecision = "approve" | "reject" | "request_resubmission" | "suspend";

const DOCUMENT_NAMES: Record<string, string> = {
  national_id_front: "National ID (front)",
  national_id_back: "National ID (back)",
  drivers_licence: "Driver's licence",
  psv_badge: "PSV badge",
  good_conduct_certificate: "Good conduct certificate",
  vehicle_logbook: "Vehicle logbook",
  commercial_insurance: "Commercial insurance",
  vehicle_photo_front: "Vehicle photo (front)",
  vehicle_photo_back: "Vehicle photo (back)",
  vehicle_photo_side: "Vehicle photo (side)",
  driver_selfie_liveness: "Selfie (liveness)",
};

/** The order a reviewer checks documents in: the person, then the vehicle. */
export const ORDER = Object.keys(DOCUMENT_NAMES);

export function docName(type: string): string {
  return DOCUMENT_NAMES[type] ?? label(type);
}

const DOCUMENT_COPY: Record<DocumentDecision, { title: string; submit: string; done: string; reason: boolean }> = {
  approve: { title: "Approve this document?", submit: "Approve", done: "Document approved", reason: false },
  reject: { title: "Reject this document", submit: "Reject", done: "Document rejected", reason: true },
  request_resubmission: { title: "Ask for a new upload", submit: "Ask again", done: "Driver asked to upload it again", reason: true },
};

export function DocumentDecisionDialog({ value, onClose, onDone }: { value: { doc: Schemas["ReviewableDocument"]; decision: DocumentDecision } | null; onClose: () => void; onDone: () => Promise<void> }) {
  const [reason, setReason] = useState("");
  const copy = value ? DOCUMENT_COPY[value.decision] : DOCUMENT_COPY.approve;
  return (
    <ActionDialog
      open={value !== null}
      onOpenChange={(open) => {
        if (!open) {
          setReason("");
          onClose();
        }
      }}
      title={copy.title}
      description={value ? `${docName(value.doc.document.document_type)}, version ${value.doc.document.version}.` : undefined}
      submitLabel={copy.submit}
      destructive={value?.decision === "reject"}
      done={copy.done}
      onSubmit={async () => {
        if (!value) return;
        await api.post("/v1/ops/verification/documents/{document_id}/review", {
          path: { document_id: value.doc.document.id },
          body: { decision: value.decision, reason: copy.reason ? reason.trim() : undefined },
        });
        setReason("");
        await onDone();
      }}
    >
      {copy.reason ? (
        <FormField label="Reason" hint="Shown to the driver, so keep it clear and kind. Up to 500 characters.">
          <Textarea required maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
        </FormField>
      ) : null}
    </ActionDialog>
  );
}

const APPLICATION_COPY: Record<ApplicationDecision, { title: string; intro: string; submit: string; done: string }> = {
  approve: { title: "Approve this driver?", intro: "They can pay the weekly subscription and go online.", submit: "Approve driver", done: "Driver approved" },
  request_resubmission: { title: "Ask for resubmission", intro: "The driver is notified and asked to upload documents again.", submit: "Send request", done: "Resubmission requested" },
  reject: { title: "Reject this application", intro: "The driver cannot drive with Liddr on this application.", submit: "Reject", done: "Application rejected" },
  suspend: { title: "Suspend this driver", intro: "For fraud or safety concerns. The driver is notified and cannot drive while suspended.", submit: "Suspend", done: "Driver suspended" },
};

export function ApplicationDecisionDialog({ applicationID, decision, onClose, onDone }: { applicationID?: string; decision: ApplicationDecision | null; onClose: () => void; onDone: () => Promise<void> }) {
  const [reason, setReason] = useState("");
  const copy = APPLICATION_COPY[decision ?? "approve"];
  const needsReason = decision !== "approve";
  return (
    <ActionDialog
      open={decision !== null}
      onOpenChange={(open) => {
        if (!open) {
          setReason("");
          onClose();
        }
      }}
      title={copy.title}
      description={copy.intro}
      submitLabel={copy.submit}
      destructive={decision === "reject" || decision === "suspend"}
      done={copy.done}
      onSubmit={async () => {
        if (!decision || !applicationID) return;
        await api.post("/v1/ops/verification/applications/{application_id}/review", {
          path: { application_id: applicationID },
          body: { decision, reason: reason.trim() || undefined },
        });
        setReason("");
        await onDone();
      }}
    >
      <FormField label={needsReason ? "Reason" : "Note (optional)"} hint="Recorded with your decision. Up to 500 characters.">
        <Textarea required={needsReason} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
      </FormField>
    </ActionDialog>
  );
}
