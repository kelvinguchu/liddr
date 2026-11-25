import { useState, type FormEvent, type ReactNode } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { QRCodeSVG } from "qrcode.react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { CodeBoxes } from "@/components/code-boxes";
import { CheckIcon, ChevronLeftIcon, ChevronRightIcon, CopyIcon, ShieldCheckIcon } from "lucide-react";
import { cn } from "@/lib/utils";
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
    <main className="grid min-h-dvh grid-cols-1 place-items-center bg-chrome px-4 py-10">
      <div className="flex w-full max-w-sm flex-col items-center gap-5 text-center">
        <img src="/logo-for-light-mode.svg?v=fleet" alt="liddr" width={74} height={32} className="h-8 w-auto dark:hidden" />
        <img src="/logo-for-dark-mode.svg?v=fleet" alt="liddr" width={74} height={32} className="hidden h-8 w-auto dark:block" />
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
// route opens: start, scan the code (or type the key), then confirm with a code.
function Enrol() {
  const queryClient = useQueryClient();
  const setup = useMutation({ mutationFn: () => api.post("/v1/auth/mfa/totp/setup") });
  const [code, setCode] = useState("");
  const [typing, setTyping] = useState(false);
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
  const uri = setup.data?.otpauth_uri ?? "";

  function submit(event: FormEvent) {
    event.preventDefault();
    confirm.mutate();
  }

  return (
    <main className="grid min-h-dvh grid-cols-1 place-items-center bg-chrome px-4 py-10">
      <div className="flex w-full max-w-[440px] flex-col gap-6 rounded-[20px] border bg-card p-6 sm:p-8">
        {!secret ? (
          <>
            <span aria-hidden className="grid size-14 place-items-center rounded-full bg-brand/12 text-brand-ink">
              <ShieldCheckIcon className="size-7" />
            </span>
            <EnrolHeading step={1} title="Turn on two-step sign-in" line="Staff sign in with a code from an authenticator app." />
            {setup.isError ? (
              <Alert variant="destructive">
                <AlertDescription>{problemText(setup.error)}</AlertDescription>
              </Alert>
            ) : null}
            <Button className="h-12 rounded-xl text-base font-semibold" onClick={() => setup.mutate()} disabled={setup.isPending}>
              {setup.isPending ? "Preparing…" : "Start setup"}
            </Button>
          </>
        ) : (
          <>
            {typing ? (
              <>
                <EnrolHeading step={2} title="Enter this key" line="In your authenticator app, add an account and choose to enter a key." />
                <SetupKey secret={secret} account={accountName(uri)} />
                <LinkAction onClick={() => setTyping(false)} back>
                  Scan the code instead
                </LinkAction>
              </>
            ) : (
              <>
                <EnrolHeading step={2} title="Scan this code" line="Use your authenticator app, then enter the code it shows." />
                <div className="flex flex-col items-center gap-2 rounded-2xl bg-muted p-6">
                  <div className="rounded-xl border bg-white p-3.5">
                    <QRCodeSVG value={uri} size={176} marginSize={0} fgColor="#242e3f" title="Authenticator setup code" />
                  </div>
                  <LinkAction onClick={() => setTyping(true)}>Can't scan it? Enter a setup key</LinkAction>
                </div>
              </>
            )}
            <form onSubmit={submit} className="flex flex-col gap-3">
              <label htmlFor="enrol-code" className="text-body font-semibold">
                Code from your app
              </label>
              <CodeBoxes id="enrol-code" label="6-digit code from your app" value={code} onChange={setCode} />
              {confirm.isError ? (
                <Alert variant="destructive" role="alert">
                  <AlertDescription>{problemText(confirm.error)}</AlertDescription>
                </Alert>
              ) : null}
              <Button type="submit" className="mt-2 h-12 rounded-xl text-base font-semibold" disabled={confirm.isPending || code.length !== 6}>
                {confirm.isPending ? "Confirming…" : "Confirm"}
              </Button>
            </form>
          </>
        )}
      </div>
    </main>
  );
}

function EnrolHeading({ step, title, line }: { step: 1 | 2; title: string; line: string }) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2">
        <span aria-hidden className="h-1 w-6 rounded-full bg-brand" />
        <span aria-hidden className={cn("h-1 w-6 rounded-full", step === 2 ? "bg-brand" : "bg-accent")} />
        <span className="ml-1 text-meta font-semibold text-muted-foreground">Step {step} of 2</span>
      </div>
      <h1 className="text-[1.625rem] leading-8 font-bold tracking-tight">{title}</h1>
      <p className="text-[0.9375rem] leading-[1.375rem] text-muted-foreground">{line}</p>
    </div>
  );
}

// The key for an app that can't scan: one value on one line, with Copy, so it
// never looks like a list of backup codes.
function SetupKey({ secret, account }: { secret: string; account: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(secret);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard refused (an old browser or a denied permission): the key stays selectable to copy by hand.
      setCopied(false);
    }
  }
  return (
    <div className="flex flex-col gap-3 rounded-2xl bg-muted p-5">
      {account ? (
        <div className="flex flex-col gap-1">
          <span className="text-meta font-semibold text-muted-foreground">Account</span>
          <span className="text-[0.9375rem] font-semibold">{account}</span>
        </div>
      ) : null}
      <div className="flex flex-col gap-1.5">
        <div className="flex items-center justify-between gap-2">
          <span id="setup-key-label" className="text-meta font-semibold text-muted-foreground">
            Setup key
          </span>
          <Button type="button" variant="ghost" className="h-8 gap-1.5 rounded-lg px-2 font-semibold text-brand-ink" onClick={copy}>
            {copied ? <CheckIcon className="size-4" /> : <CopyIcon className="size-4" />}
            {copied ? "Copied" : "Copy"}
          </Button>
        </div>
        {/* One value in one field: a single line where it fits, wrapping once on a phone, never cut off. */}
        <div className="rounded-xl border bg-background px-3.5 py-3">
          <span aria-labelledby="setup-key-label" className="font-mono text-[0.78rem] tracking-[0.01em] select-all">
            {secret.match(/.{1,4}/g)?.join(" ")}
          </span>
        </div>
      </div>
      <span className="text-meta text-muted-foreground">Choose &ldquo;time based&rdquo; if your app asks.</span>
    </div>
  );
}

function LinkAction({ onClick, back, children }: { onClick: () => void; back?: boolean; children: ReactNode }) {
  return (
    <button type="button" onClick={onClick} className="inline-flex min-h-11 items-center gap-1 self-center text-body font-semibold text-brand-ink hover:underline">
      {back ? <ChevronLeftIcon className="size-4" /> : null}
      {children}
      {back ? null : <ChevronRightIcon className="size-4" />}
    </button>
  );
}

// The name an authenticator app files the key under, from the otpauth link's label.
function accountName(uri: string): string {
  const label = uri.match(/^otpauth:\/\/totp\/([^?]+)/)?.[1];
  if (!label) return "";
  try {
    return decodeURIComponent(label).replace(":", " · ");
  } catch {
    return "";
  }
}
