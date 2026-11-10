import { Badge, type BadgeVariant } from "@/components/ui/badge";
import { label } from "@/lib/format";

// The tone says what a status means for the reviewer: green done, amber
// waiting on someone, red refused or harmful, blue in force, grey closed.
const TONES: Record<string, BadgeVariant> = {};
for (const [tone, statuses] of Object.entries({
  ok: ["approved", "validated", "clean", "success", "paid", "resolved"],
  warn: ["pending", "pending_review", "under_review", "submitted", "triaged", "scanning", "resubmission_required", "pending_callback", "initiated", "needs_review"],
  crit: ["rejected", "suspended", "infected", "failed", "timeout", "permanent_ban"],
  info: ["active"],
  none: ["cancelled", "dismissed", "expired", "lifted"],
} satisfies Record<string, string[]>)) {
  for (const status of statuses) TONES[status] = tone as BadgeVariant;
}

export function StatusBadge({ status, text, tone }: { status: string; text?: string; tone?: BadgeVariant }) {
  return <Badge variant={tone ?? TONES[status] ?? "default"}>{text ?? label(status)}</Badge>;
}

/** Report and dispute severity, 1 (low) to 5. */
export function SeverityBadge({ level }: { level: number }) {
  return <Badge variant={level >= 4 ? "crit" : level >= 2 ? "warn" : "default"}>Level {level}</Badge>;
}
