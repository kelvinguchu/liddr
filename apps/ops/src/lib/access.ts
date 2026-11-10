// Who may use the console. This mirrors the contract's scopes so the console
// only offers what the API will allow; the API enforces the same rule on every
// call, so this decides presentation, never permission.

export type Role = "rider" | "driver" | "ops" | "admin";

/** Every console route is open to ops and admin, and to no one else. */
export function isStaff(roles: readonly string[]): boolean {
  return roles.includes("ops") || roles.includes("admin");
}

export function roleLabel(roles: readonly string[]): string {
  if (roles.includes("admin")) return "Admin";
  if (roles.includes("ops")) return "Operations";
  return "No staff access";
}
