import { useState, type FormEvent, type ReactNode } from "react";
import { toast } from "sonner";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { problemText } from "@/lib/api";
import { StepUpCancelled } from "@/lib/step-up";

/**
 * A decision in a dialog. The form's own validation runs first; then onSubmit
 * does the work and throws to keep the dialog open with the error shown.
 * Closing the authenticator prompt leaves the dialog as it was.
 */
export function ActionDialog({
  open,
  onOpenChange,
  title,
  description,
  submitLabel,
  destructive,
  done,
  onSubmit,
  children,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: ReactNode;
  submitLabel: string;
  destructive?: boolean;
  /** The toast once it succeeded. */
  done: string;
  onSubmit: () => Promise<void>;
  children?: ReactNode;
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    setError("");
    setPending(true);
    try {
      await onSubmit();
      toast.success(done);
      onOpenChange(false);
    } catch (err) {
      if (!(err instanceof StepUpCancelled)) setError(problemText(err));
    } finally {
      setPending(false);
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) setError("");
        onOpenChange(next);
      }}
    >
      <DialogContent className="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-md">
        <form onSubmit={submit} className="flex flex-col gap-4">
          <DialogHeader className="text-left">
            <DialogTitle className="text-section">{title}</DialogTitle>
            <DialogDescription className={description ? "text-cell" : "sr-only"}>{description ?? title}</DialogDescription>
          </DialogHeader>
          {children}
          {error ? (
            <Alert variant="destructive" role="alert">
              <AlertDescription>{error}</AlertDescription>
            </Alert>
          ) : null}
          <DialogFooter className="flex-row justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" variant={destructive ? "destructive" : "default"} disabled={pending}>
              {pending ? "Working…" : submitLabel}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/** A labelled control with an optional hint under it. */
export function FormField({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1.5">
      <span className="text-cell font-medium">{label}</span>
      {children}
      {hint ? <span className="text-meta text-muted-foreground">{hint}</span> : null}
    </label>
  );
}

/** A native select styled like the inputs: dialogs need no popover inside them. */
export function NativeSelect({ value, onChange, options, name }: { value: string; onChange: (value: string) => void; options: readonly (readonly [string, string])[]; name: string }) {
  return (
    <select
      name={name}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="h-9 w-full rounded-md border border-input bg-background px-3 text-body shadow-xs outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 dark:bg-input/30"
    >
      {options.map(([v, text]) => (
        <option key={v} value={v}>
          {text}
        </option>
      ))}
    </select>
  );
}
