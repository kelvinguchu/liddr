import { useQuery } from "@tanstack/react-query";
import { api, ApiError } from "./api";

/** Whether this session may use staff routes, and what stands in the way if not. */
export type StaffAccess = "ok" | "enrol" | "blocked" | "not-staff";

export function useAccount() {
  return useQuery({ queryKey: ["me"], queryFn: () => api.get("/v1/me"), staleTime: 5 * 60_000 });
}

/**
 * Asks a cheap staff route whether this session gets through. The API answers
 * MFA_ENROLMENT_REQUIRED until an authenticator is set up, and
 * ADDRESS_NOT_ALLOWED outside the office networks.
 */
export function useStaffAccess(enabled: boolean) {
  return useQuery({
    queryKey: ["staff-access"],
    enabled,
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<StaffAccess> => {
      try {
        await api.get("/v1/ops/moderation/enforcements/metrics");
        return "ok";
      } catch (err) {
        if (!(err instanceof ApiError)) throw err;
        if (err.code === "MFA_ENROLMENT_REQUIRED") return "enrol";
        if (err.code === "ADDRESS_NOT_ALLOWED") return "blocked";
        if (err.code === "FORBIDDEN" || err.code === "NOT_STAFF") return "not-staff";
        throw err;
      }
    },
  });
}
