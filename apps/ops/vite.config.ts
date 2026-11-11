import { fileURLToPath, URL } from "node:url";
import { defineConfig, type ProxyOptions } from "vite";
import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import viteReact from "@vitejs/plugin-react";
import { nitro } from "nitro/vite";

// The app runs as its own Node service. In production the proxy in front
// (README, "Production routing") sends /v1 to the Go API and everything else
// here, so the API's session cookie applies to the app's same-origin calls and
// the app never holds a credential.
//
// In development the dev server forwards /v1 to the local API
// (LIDDR_DEV_API, default http://127.0.0.1:8080), which must run with
// OPS_CONSOLE_ORIGIN=http://127.0.0.1:5173 so it accepts this page.
function devProxy(): Record<string, ProxyOptions> {
  const target = process.env.LIDDR_DEV_API ?? "http://127.0.0.1:8080";
  return { "/v1": { target, changeOrigin: false, secure: false } };
}

export default defineConfig(({ command }) => ({
  resolve: {
    alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) },
  },
  build: {
    sourcemap: false,
    target: "es2022",
  },
  server: {
    host: "127.0.0.1",
    proxy: command === "serve" ? devProxy() : undefined,
  },
  plugins: [
    tailwindcss(),
    tanstackStart(),
    ...(command === "build" ? [nitro({ plugins: [fileURLToPath(new URL("./src/server/document-cache.ts", import.meta.url))] })] : []),
    viteReact(),
  ],
}));
