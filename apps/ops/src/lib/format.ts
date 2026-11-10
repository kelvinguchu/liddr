// Display formats. Times are Nairobi time whatever the reviewer's device says,
// since every record is about a trip in Kenya.

const dateTime = new Intl.DateTimeFormat("en-KE", { dateStyle: "medium", timeStyle: "short", timeZone: "Africa/Nairobi" });
const dateOnly = new Intl.DateTimeFormat("en-KE", { dateStyle: "medium", timeZone: "Africa/Nairobi" });
const shillings = new Intl.NumberFormat("en-KE");

/** An API timestamp in Nairobi time, or a dash. */
export function when(value: string | null | undefined): string {
  if (!value) return "—";
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? "—" : dateTime.format(d);
}

/** An ISO date (no time) as a Nairobi calendar day. */
export function day(value: string | null | undefined): string {
  if (!value) return "—";
  const d = new Date(`${value}T00:00:00+03:00`);
  return Number.isNaN(d.getTime()) ? value : dateOnly.format(d);
}

export function kes(amount: number | null | undefined): string {
  return amount === undefined || amount === null ? "—" : `KES ${shillings.format(amount)}`;
}

/** snake_case to a sentence: "pending_review" becomes "Pending review". */
export function label(value: string | null | undefined): string {
  if (!value) return "—";
  const text = value.replaceAll("_", " ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** The first block of an ID, enough to tell records apart on screen. */
export function shortID(id: string | null | undefined): string {
  return id ? id.slice(0, 8) : "—";
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUUID(value: string): boolean {
  return uuid.test(value.trim());
}

/**
 * Reads a datetime-local value as Nairobi time (UTC+3, no daylight saving)
 * and returns it as ISO. Throws when it is missing, unreadable or past.
 */
export function nairobiFuture(value: string, now = Date.now()): string {
  const d = new Date(`${value}:00+03:00`);
  if (!value || Number.isNaN(d.getTime())) throw new Error("Enter a valid date and time.");
  if (d.getTime() <= now) throw new Error("Choose a time in the future.");
  return d.toISOString();
}

/** Initials for an avatar: "Wanjiru Kamau" becomes "WK". */
export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "ST";
  return (parts.length === 1 ? parts[0].slice(0, 2) : parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}
