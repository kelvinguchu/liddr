import type { ReactNode } from "react";
import { createRootRouteWithContext, HeadContent, Outlet, Scripts, useRouterState } from "@tanstack/react-router";
import { QueryClientProvider, type QueryClient } from "@tanstack/react-query";
import { ThemeProvider } from "next-themes";
import { Toaster } from "sonner";
import { AppShell } from "@/components/layout/app-shell";
import { SessionGate } from "@/components/session-gate";
import { StepUpDialog } from "@/components/step-up-dialog";
import { TooltipProvider } from "@/components/ui/tooltip";
import appCss from "@/styles.css?url";

interface RouterContext {
  queryClient: QueryClient;
}

export const Route = createRootRouteWithContext<RouterContext>()({
  // A signed-in console: every view depends on the session, so routes render
  // in the browser only. The server sends the document, fonts and theme script.
  ssr: false,
  head: () => ({
    meta: [{ charSet: "utf-8" }, { name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover" }, { name: "robots", content: "noindex" }, { title: "Liddr Ops" }],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/icon.svg", type: "image/svg+xml" },
    ],
  }),
  shellComponent: RootDocument,
  component: RootComponent,
  notFoundComponent: () => <p className="p-6 text-cell text-muted-foreground">This page does not exist.</p>,
});

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

// /signin stands alone. Every other route waits behind SessionGate: the
// console's frame is never shown to a browser the API has not answered for.
function RootComponent() {
  const { queryClient } = Route.useRouteContext();
  const standalone = useRouterState({ select: (s) => s.location.pathname === "/signin" });
  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
      <QueryClientProvider client={queryClient}>
        <TooltipProvider delayDuration={250}>
          {standalone ? (
            <Outlet />
          ) : (
            <SessionGate>
              <AppShell>
                <Outlet />
              </AppShell>
              <StepUpDialog />
            </SessionGate>
          )}
          <Toaster position="bottom-right" closeButton toastOptions={{ classNames: { toast: "!font-sans !text-cell", description: "!text-muted-foreground" } }} />
        </TooltipProvider>
      </QueryClientProvider>
    </ThemeProvider>
  );
}
