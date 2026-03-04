# Liddr Engineering Baseline

Last updated: March 3, 2026
Status: Mandatory repository baseline

## Purpose
Define the minimum acceptable standard for product quality in Liddr across:
- UI/UX and design quality
- latency and performance
- security and privacy

This document applies to API, Android, iOS, and docs/contract work.

## Pillar 1: UI/UX and Design Baseline

### Product experience
- Build clear, intentional flows; avoid placeholder screens and dead ends.
- Every primary action must have visible state: idle, loading, success, error.
- Error copy must be actionable and specific.

### Visual consistency
- Use shared theme tokens and typography; avoid one-off styling.
- No hardcoded ad-hoc colors in feature code when theme tokens exist.
- Keep spacing, typography hierarchy, and component behavior consistent.

### Accessibility minimum
- Meet WCAG AA contrast for text and key UI surfaces.
- Interactive targets should be at least 44x44dp.
- Support dynamic type/font scaling without layout breakage.
- Ensure screen reader labels for critical controls and status text.

## Pillar 2: Latency and Performance Baseline

### User-perceived responsiveness
- TTI for key entry screens should feel instant on modern devices.
- UI actions should acknowledge user input immediately.
- Long operations must show progress feedback quickly.

### Baseline budgets (target)
- API p95 for common read/write endpoints: < 300ms in-region.
- Realtime event delivery and client update p95: < 300ms.
- Mobile interaction response for local actions: < 100ms.
- Scrolling should remain smooth (target 60fps on common devices).

### Engineering practices
- Prefer pagination and incremental loading over large payloads.
- Avoid blocking main/UI thread on mobile.
- Keep serialization and query paths lean on API hot routes.
- Measure before and after for performance-sensitive changes.

## Pillar 3: Security and Privacy Baseline

### Repository-wide requirements
- Apply least privilege and deny-by-default for protected operations.
- Treat identity, location, payments, and verification data as high risk.
- Log high-risk actions with auditable context.

### Required references
- API security controls are mandatory in `api/SECURITY_BASELINE.md`.
- No high-risk feature is complete without security checks and tests.

### Non-negotiables
- No secrets in repository, fixtures, logs, screenshots, or docs.
- No client-controlled sensitive ownership fields (set from auth context).
- No protected endpoint without both authentication and role authorization.

## Definition of Done (Cross-Platform)
- UX: flow is coherent, accessible, and visually aligned with theme/design.
- Performance: no known regression on critical paths.
- Security: required controls enforced and tested for touched areas.
- Docs: contracts and behavior updated when implementation changes.

## Codex Operating Rules
- Before major edits, identify which of the 3 pillars are impacted.
- For each impacted pillar, include at least one explicit verification step.
- If a tradeoff is unavoidable, document the risk and proposed mitigation.
