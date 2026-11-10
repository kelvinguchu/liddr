import { definePlugin } from "nitro";

// A response whose policy holds a nonce is never cached: a replayed page is a
// page whose nonce is known. This runs as the last step of a response because
// nothing earlier has the last word. Nitro's route rule for /assets sets a year
// of immutable on whatever is answered there, and that includes the not-found
// page the app renders for a file the build does not have.
export default definePlugin((app) => {
  app.hooks?.hook("response", (response) => {
    if (response.headers.get("content-security-policy")?.includes("'nonce-")) {
      response.headers.set("Cache-Control", "no-store");
    }
  });
});
