import { useQuery } from "@tanstack/react-query";
import { CheckIcon, ExternalLinkIcon } from "lucide-react";
import { docName, type DocumentDecision } from "@/components/documents/decisions";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { api, problemText, type Schemas } from "@/lib/api";
import { when } from "@/lib/format";

// One document, large, with the decisions beside it so a reviewer never
// scrolls between the file and the buttons. Full screen on a phone. The link
// is fetched fresh each time: it is signed and expires within minutes.
export function DocumentViewer({ doc, canDecide, onClose, onDecide }: { doc: Schemas["ReviewableDocument"] | null; canDecide: boolean; onClose: () => void; onDecide: (decision: DocumentDecision) => void }) {
  const link = useQuery({
    queryKey: ["document-link", doc?.document.id],
    enabled: doc !== null,
    staleTime: 0,
    gcTime: 0,
    queryFn: () => api.post("/v1/ops/verification/documents/{document_id}/download", { path: { document_id: doc?.document.id ?? "" } }),
  });
  const name = doc ? docName(doc.document.document_type) : "Document";
  const image = doc?.content_type.startsWith("image/");

  return (
    <Dialog open={doc !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="flex h-dvh max-h-dvh w-full max-w-none flex-col gap-0 rounded-none border-0 p-0 sm:h-auto sm:max-h-[calc(100dvh-2rem)] sm:max-w-[min(980px,calc(100vw-2rem))] sm:rounded-xl sm:border">
        <div className="flex items-start justify-between gap-4 px-4 pt-4 pb-3 pe-12 sm:px-5">
          <div className="min-w-0">
            <DialogTitle className="text-section">{name}</DialogTitle>
            <DialogDescription className="text-meta">
              Version {doc?.document.version}
              {link.data ? ` · link expires ${when(link.data.expires_at)}` : ""}
            </DialogDescription>
          </div>
        </div>
        <div className="mx-3 grid min-h-0 flex-1 place-items-center overflow-auto rounded-lg border bg-muted p-3 sm:mx-5 sm:min-h-80">
          {link.isPending ? (
            <Skeleton className="h-64 w-full max-w-md" />
          ) : link.isError ? (
            <p className="text-cell text-destructive">{problemText(link.error)}</p>
          ) : image ? (
            <img src={link.data.url} alt={name} referrerPolicy="no-referrer" className="max-h-full max-w-full rounded-md object-contain sm:max-h-[calc(100dvh-14rem)]" />
          ) : (
            <p className="text-cell text-muted-foreground">This document is a PDF. Open it in a new tab to read it.</p>
          )}
        </div>
        <div className="grid grid-cols-3 gap-2 px-3 pt-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] sm:flex sm:items-center sm:px-5 sm:pb-4">
          <Button variant="outline" size="sm" className="col-span-3 sm:mr-auto" disabled={!link.data} asChild={Boolean(link.data)}>
            {link.data ? (
              <a href={link.data.url} target="_blank" rel="noopener noreferrer">
                <ExternalLinkIcon />
                Open in new tab
              </a>
            ) : (
              <span>Open in new tab</span>
            )}
          </Button>
          {canDecide ? (
            <>
              <Button variant="ghost" size="sm" onClick={() => onDecide("request_resubmission")}>
                Ask again
              </Button>
              <Button variant="outline" size="sm" className="text-destructive" onClick={() => onDecide("reject")}>
                Reject
              </Button>
              <Button size="sm" onClick={() => onDecide("approve")}>
                <CheckIcon />
                Approve
              </Button>
            </>
          ) : null}
        </div>
      </DialogContent>
    </Dialog>
  );
}
