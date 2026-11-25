import { useState } from "react";
import { cn } from "@/lib/utils";

const LENGTH = 6;

// Six boxes for a one-time code. They are drawn only: one real input lies over
// them, so typing, pasting a whole code and the browser's one-time-code
// autofill all work, and a screen reader hears a single field.
export function CodeBoxes({ id, value, onChange, label, autoFocus }: { id: string; value: string; onChange: (code: string) => void; label: string; autoFocus?: boolean }) {
  const [focused, setFocused] = useState(false);
  const current = Math.min(value.length, LENGTH - 1);
  return (
    <div className="relative">
      <div aria-hidden className="grid grid-cols-6 gap-2">
        {Array.from({ length: LENGTH }, (_, index) => (
          <div
            key={index}
            className={cn(
              "grid h-14 place-items-center rounded-xl border bg-background font-mono text-2xl font-medium text-foreground transition-colors",
              focused && index === current ? "border-2 border-ring" : "border-input",
            )}
          >
            {value[index] ?? ""}
          </div>
        ))}
      </div>
      <input
        id={id}
        required
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]{6}"
        maxLength={LENGTH}
        aria-label={label}
        autoFocus={autoFocus}
        value={value}
        onChange={(event) => onChange(event.target.value.replace(/\D/g, "").slice(0, LENGTH))}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        className="absolute inset-0 size-full cursor-text caret-transparent opacity-0"
      />
    </div>
  );
}
