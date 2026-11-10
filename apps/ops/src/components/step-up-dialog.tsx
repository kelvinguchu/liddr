import { useState, type FormEvent } from "react";
import { ShieldCheckIcon } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { confirmStepUp, problemText } from "@/lib/api";
import { stepUpCancelled, stepUpConfirmed, useStepUp } from "@/lib/step-up";

// Asks for a fresh authenticator code when an action needs one (lib/step-up).
// The action that asked retries on its own once the code is confirmed.
export function StepUpDialog() {
  const { asking } = useStepUp();
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setPending(true);
    setError("");
    try {
      stepUpConfirmed(await confirmStepUp(code.trim()));
      setCode("");
    } catch (err) {
      setError(problemText(err));
    } finally {
      setPending(false);
    }
  }

  return (
    <Dialog
      open={asking}
      onOpenChange={(open) => {
        if (open) return;
        setCode("");
        setError("");
        stepUpCancelled();
      }}
    >
      <DialogContent className="sm:max-w-sm">
        <form onSubmit={submit} className="flex flex-col gap-4">
          <DialogHeader className="items-start text-left">
            <span className="mb-1 grid size-10 place-items-center rounded-full bg-brand/12 text-brand-ink">
              <ShieldCheckIcon className="size-5" />
            </span>
            <DialogTitle className="text-section">Confirm with your authenticator</DialogTitle>
            <DialogDescription className="text-cell">High-risk actions need a fresh code. It covers the next five minutes.</DialogDescription>
          </DialogHeader>
          <Input
            autoFocus
            required
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9]{6}"
            maxLength={6}
            aria-label="6-digit code"
            placeholder="6-digit code"
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
            className="h-11 text-center font-mono text-lg tracking-[0.4em] placeholder:font-sans placeholder:text-body placeholder:tracking-normal"
          />
          {error ? (
            <Alert variant="destructive" role="alert">
              <AlertDescription>{error}</AlertDescription>
            </Alert>
          ) : null}
          <DialogFooter className="flex-row justify-end gap-2">
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setCode("");
                setError("");
                stepUpCancelled();
              }}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={pending || code.length !== 6}>
              {pending ? "Checking…" : "Confirm"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
