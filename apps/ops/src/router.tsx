import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { getGlobalStartContext } from "@tanstack/react-start";
import { ApiError } from "@/lib/api";
import { StepUpCancelled } from "@/lib/step-up";
import { routeTree } from "./routeTree.gen";

export function getRouter() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 15_000,
        refetchOnWindowFocus: true,
        // A refusal will not get better by asking again.
        retry: (count, error) => !(error instanceof ApiError && error.status > 0) && !(error instanceof StepUpCancelled) && count < 2,
      },
    },
  });
  return createRouter({
    routeTree,
    context: { queryClient },
    defaultPreload: "intent",
    scrollRestoration: true,
    // The response's nonce (start.ts). Undefined in the browser, where the
    // framework reads it back from the document.
    ssr: { nonce: getGlobalStartContext()?.nonce },
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
