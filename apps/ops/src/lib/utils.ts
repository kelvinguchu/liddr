import { clsx, type ClassValue } from "clsx";
import { extendTailwindMerge } from "tailwind-merge";

// The app's type scale (styles.css) adds font sizes tailwind-merge does not
// know; without them "text-figure text-warn" would read as two colours and
// drop the size.
const twMerge = extendTailwindMerge({
  extend: { theme: { text: ["micro", "meta", "cell", "body", "section", "title", "figure-sm", "figure"] } },
});

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
