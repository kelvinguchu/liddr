import { useState, type FormEvent } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { ArrowLeftIcon } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { problemText, startSession, ApiError } from "@/lib/api";

// Where to go after signing in: only a path on this site, never an address.
function safeNext(value: unknown): string {
  return typeof value === "string" && value.startsWith("/") && !value.startsWith("//") && value !== "/signin" ? value : "/documents";
}

export const Route = createFileRoute("/signin")({
  validateSearch: (search: Record<string, unknown>) => ({ next: safeNext(search.next) }),
  component: SignIn,
});

async function requestCode(phone: string): Promise<string> {
  const response = await fetch("/v1/auth/otp/request", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "application/json", "X-Liddr-Console": "1" },
    body: JSON.stringify({ phone, role: "staff" }),
  });
  const body = (await response.json().catch(() => ({}))) as { challenge_id?: string; code?: string; message?: string; request_id?: string };
  if (!response.ok || !body.challenge_id) throw new ApiError(response.status, body.code ?? "HTTP_" + response.status, body.message ?? "We could not send a code. Please try again.", body.request_id);
  return body.challenge_id;
}

// Staff sign in with the phone number an admin granted access to, then the
// code sent to it. The API sets the session cookies; nothing is kept here.
function SignIn() {
  const { next } = Route.useSearch();
  const [phone, setPhone] = useState("");
  const [challenge, setChallenge] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);

  async function run(event: FormEvent, work: () => Promise<void>) {
    event.preventDefault();
    setError("");
    setPending(true);
    try {
      await work();
    } catch (err) {
      setError(problemText(err));
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="flex min-h-dvh bg-background">
      <div className="relative hidden w-[45%] items-center justify-center bg-[linear-gradient(140deg,#0b2545,#13315c_70%,#0e3b58)] text-white lg:flex">
        <div className="flex flex-col items-center gap-4">
          <img src="/logo-for-dark-mode.svg" alt="liddr" width={148} height={64} className="h-14 w-auto" />
          <p className="text-cell text-white/70">Operations console</p>
        </div>
        <p className="absolute bottom-6 text-meta text-white/55">For Liddr staff only. Every action is recorded.</p>
      </div>
      <div className="flex min-w-0 flex-1 overflow-y-auto">
        <div className="m-auto flex w-full max-w-sm flex-col gap-6 px-4 py-10">
          <div className="flex justify-center lg:hidden">
            <img src="/logo-for-light-mode.svg" alt="liddr" width={74} height={32} className="h-9 w-auto dark:hidden" />
            <img src="/logo-for-dark-mode.svg" alt="liddr" width={74} height={32} className="hidden h-9 w-auto dark:block" />
          </div>
          {!challenge ? (
            <form className="flex flex-col gap-5" onSubmit={(e) => run(e, async () => setChallenge(await requestCode(phone.trim())))}>
              <div className="flex flex-col gap-1">
                <h1 className="text-[1.5rem] leading-8 font-semibold tracking-tight">Sign in</h1>
                <p className="text-cell text-muted-foreground">Use the phone number your admin gave staff access to.</p>
              </div>
              <label className="flex flex-col gap-1.5">
                <span className="text-cell font-medium">Phone number</span>
                <Input required autoFocus type="tel" inputMode="tel" autoComplete="tel" placeholder="0712 345 678" value={phone} onChange={(e) => setPhone(e.target.value)} className="h-11 text-base" />
              </label>
              {error ? (
                <Alert variant="destructive" role="alert">
                  <AlertDescription>{error}</AlertDescription>
                </Alert>
              ) : null}
              <Button type="submit" className="h-11" disabled={pending}>
                {pending ? "Sending…" : "Send code"}
              </Button>
            </form>
          ) : (
            <form
              className="flex flex-col gap-5"
              onSubmit={(e) =>
                run(e, async () => {
                  await startSession(challenge, code.trim());
                  window.location.assign(next);
                })
              }
            >
              <div className="flex flex-col gap-1">
                <h1 className="text-[1.5rem] leading-8 font-semibold tracking-tight">Check your phone</h1>
                <p className="text-cell text-muted-foreground">Enter the 6-digit code sent to {phone}.</p>
              </div>
              <Input
                required
                autoFocus
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                maxLength={6}
                aria-label="6-digit code"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                className="h-12 text-center font-mono text-xl tracking-[0.4em] placeholder:font-sans placeholder:text-body placeholder:tracking-normal"
              />
              {error ? (
                <Alert variant="destructive" role="alert">
                  <AlertDescription>{error}</AlertDescription>
                </Alert>
              ) : null}
              <Button type="submit" className="h-11" disabled={pending || code.length !== 6}>
                {pending ? "Signing in…" : "Sign in"}
              </Button>
              <Button
                type="button"
                variant="ghost"
                className="self-center"
                onClick={() => {
                  setChallenge("");
                  setCode("");
                  setError("");
                }}
              >
                <ArrowLeftIcon className="size-4" />
                Use a different number
              </Button>
            </form>
          )}
        </div>
      </div>
    </div>
  );
}
