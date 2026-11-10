import { useState, type FormEvent, type ReactNode } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { QRCodeSVG } from "qrcode.react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { api, ApiError, endSession, problemText } from "@/lib/api";
import { useAccount, useStaffAccess } from "@/lib/session";

// SessionGate renders the console only once the API has answered for this
// browser's session and let it through a staff route. Until then the page
// shows a quiet waiting state, never the console's frame. A signed-out browser
// is sent to sign-in by the account read itself (lib/api).
export function SessionGate({ children }: { children: ReactNode }) {
  const account = useAccount();
  const access = useStaffAccess(account.isSuccess);
  if (access.data === "ok") return <>{children}</>;
  if (access.data === "enrol") return <Enrol />;
  if (access.data === "blocked") {
    return (
      <GateFrame>
        <GateText title="Not available on this network" body="Staff tools only open from approved office networks. Connect to one, then try again." />
        <SignOut />
      </GateFrame>
    );
  }
  if (access.data === "not-staff") {
    return (
      <GateFrame>
        <GateText title="No staff access" body="This account cannot use the staff console. Ask an admin if you need access." />
        <SignOut />
      </GateFrame>
    );
  }
  const failed = account.error ?? access.error;
  const unreachable = failed && !(failed instanceof ApiError && failed.status === 401);
  return (
    <GateFrame>
      {unreachable ? (
        <>
          <p className="text-cell text-muted-foreground">{problemText(failed)}</p>
          <Button variant="outline" size="sm" onClick={() => (account.isError ? account.refetch() : access.refetch())}>
            Try again
          </Button>
        </>
      ) : (
        <p className="inline-flex items-center gap-2 text-cell text-muted-foreground" role="status" aria-live="polite">
          <Spinner className="size-4" />
          Checking your session
        </p>
      )}
    </GateFrame>
  );
}

export function GateFrame({ children }: { children: ReactNode }) {
  return (
    <main className="grid min-h-dvh place-items-center bg-chrome px-4 py-10">
      <div className="flex w-full max-w-sm flex-col items-center gap-5 text-center">
        <img src="/logo-for-light-mode.svg" alt="liddr" width={74} height={32} className="h-8 w-auto dark:hidden" />
        <img src="/logo-for-dark-mode.svg" alt="liddr" width={74} height={32} className="hidden h-8 w-auto dark:block" />
        {children}
      </div>
    </main>
  );
}

function GateText({ title, body }: { title: string; body: string }) {
  return (
    <div className="flex flex-col gap-1">
      <p className="text-section font-semibold">{title}</p>
      <p className="text-cell text-muted-foreground">{body}</p>
    </div>
  );
}

function SignOut() {
  const out = useMutation({ mutationFn: endSession, onSettled: () => window.location.assign("/signin") });
  return (
    <Button variant="outline" size="sm" onClick={() => out.mutate()} disabled={out.isPending}>
      Sign out
    </Button>
  );
}

// Enrol sets up the authenticator every staff account needs before any staff
// route opens: scan the code (or type the key), then confirm with a code.
function Enrol() {
  const queryClient = useQueryClient();
  const setup = useMutation({ mutationFn: () => api.post("/v1/auth/mfa/totp/setup") });
  const [code, setCode] = useState("");
  const confirm = useMutation({
    mutationFn: () => api.post("/v1/auth/mfa/totp/confirm", { body: { code: code.trim() } }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["staff-access"] }),
    onError: (err) => {
      if (err instanceof ApiError && err.code === "MFA_SETUP_EXPIRED") {
        setCode("");
        setup.mutate();
      }
    },
  });
  const secret = setup.data?.secret;

  function submit(event: FormEvent) {
    event.preventDefault();
    confirm.mutate();
  }

  return (
    <main className="grid min-h-dvh place-items-center bg-chrome px-4 py-10">
      <div className="flex w-full max-w-md flex-col gap-6 rounded-2xl border bg-background p-6 shadow-xs sm:p-8">
        <div className="flex flex-col gap-1">
          <p className="text-micro font-semibold tracking-[0.12em] text-brand-ink uppercase">One more step</p>
          <h1 className="text-title font-semibold tracking-tight">Set up your authenticator</h1>
          <p className="text-cell text-muted-foreground">Staff accounts confirm sign-in and high-risk actions with a code from an authenticator app.</p>
        </div>
        {!secret ? (
          <div className="flex flex-col gap-3">
            {setup.isError ? (
              <Alert variant="destructive">
                <AlertDescription>{problemText(setup.error)}</AlertDescription>
              </Alert>
            ) : null}
            <Button className="h-10" onClick={() => setup.mutate()} disabled={setup.isPending}>
              {setup.isPending ? "Preparing…" : "Start setup"}
            </Button>
          </div>
        ) : (
          <form onSubmit={submit} className="flex flex-col gap-5">
            <ol className="flex list-decimal flex-col gap-1 pl-5 text-cell text-muted-foreground">
              <li>Open Google Authenticator, Microsoft Authenticator or 1Password.</li>
              <li>Scan this code, or add an account with the key below.</li>
              <li>Enter the 6-digit code it shows.</li>
            </ol>
            <div className="flex flex-col items-center gap-3 sm:flex-row sm:items-center">
              <div className="rounded-xl border bg-white p-3">
                <QRCodeSVG value={setup.data?.otpauth_uri ?? ""} size={148} marginSize={0} title="Authenticator setup code" />
              </div>
              <div className="w-full min-w-0 rounded-xl border bg-muted p-3 text-center font-mono text-[0.95rem] font-semibold tracking-[0.08em] text-balance select-all">{secret.match(/.{1,4}/g)?.join(" ")}</div>
            </div>
            <Input
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
            {confirm.isError ? (
              <Alert variant="destructive" role="alert">
                <AlertDescription>{problemText(confirm.error)}</AlertDescription>
              </Alert>
            ) : null}
            <Button type="submit" className="h-10" disabled={confirm.isPending || code.length !== 6}>
              {confirm.isPending ? "Confirming…" : "Confirm"}
            </Button>
          </form>
        )}
      </div>
    </main>
  );
}
