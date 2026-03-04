Android-specific instructions for Liddr.

## Mandatory References
- Follow repository guardrails in `../AGENTS.md`.
- Follow quality baseline in `../docs/ENGINEERING_BASELINE.md`.

## Code Structure Rules
- Follow DRY principles and consolidate shared UI/state logic.
- Keep each code file at 250 LOC or less unless justified by clear cohesion.

## UI/UX and Design Rules
- Use the app theme and typography from `app/src/main/java/com/liddr/app/ui/theme`.
- Keep Manrope as the global font family unless an explicit product decision changes it.
- Use theme color tokens; avoid hardcoding one-off colors in feature composables.
- Implement clear loading, error, and empty states for each user flow.

## Performance Rules
- Do not block the main thread for network, disk, or heavy computation.
- Keep lists lazy and paginated where needed.
- Profile and validate critical path performance before merge.

## Security Rules
- Never hardcode API keys, tokens, or secrets in source.
- Use secure token/session handling and avoid sensitive data in logs.
- Validate auth failure and token refresh behavior in all protected flows.
