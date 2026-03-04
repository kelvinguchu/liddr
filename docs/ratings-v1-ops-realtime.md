# Ratings V1 Ops + Realtime (Human Dev Notes)

This document is for human developers and operators.  
AI agents should treat this as operational guidance, not product requirements.

## What was added

1. Ops management endpoints for ratings:
   - `GET /api/ops/ratings`
   - `GET /api/ops/ratings/excluded`
   - `GET /api/ops/ratings/users/:rated_user_id/guardrails`
   - `POST /api/ops/ratings/:id/nullify`
   - `POST /api/ops/ratings/:id/reinstate`

2. Realtime rating events:
   - `rating_pending`
   - `rating_submitted`
   - `rating_skipped`

3. Timeline persistence for replay:
   - `ride_rating_pending`
   - `ride_rated`
   - `ride_rating_skipped`
   - `ride_rating_nullified`
   - `ride_rating_reinstated`

4. Enforcement guardrails:
   - Ratings can be too sparse for reliable enforcement decisions.
   - Guardrails expose whether a user has enough recent attributable ratings.

5. Low-rating ops signals (human review only):
   - On rating submission, the API checks sustained low-rating thresholds.
   - It opens a system moderation report for ops review (no auto-ban).
   - Duplicate signals are deduplicated by rule + user + cooldown window.

6. Rating abuse ops signals (human review only):
   - Five-star velocity anomaly detection.
   - Pair concentration/collusion detection (same rater overrepresented).
   - Signals open system moderation reports for review; no direct penalties are applied automatically.

## Guardrail envs

Use these in `api/.env`:

- `RATING_ENFORCEMENT_RECENT_WINDOW_DAYS` (default `30`)
- `RATING_ENFORCEMENT_MIN_RECENT_RATINGS` (default `20`)

Guardrail snapshot includes:

- `recent_attributable_ratings`
- `minimum_required`
- `window_days`
- `ready?`

`ready? == false` means moderation/enforcement should not rely only on rating data yet.

## Ops nullification behavior

Nullifying a rating:

- sets `include_in_score = false`
- sets `exclusion_reason_code = "ops_nullified"`
- stores nullification metadata (`nullified_at`, `nullified_by_user_id`, reason, note)
- recalculates rated-user score stats

Reinstating a rating:

- clears nullification metadata
- re-applies inclusion policy based on score + reason tags
- recalculates rated-user score stats

## Notes

- `docs/aboutapp.md` is intentionally unchanged.
- Realtime notifications are additive; timeline remains source of truth for replay/sync.
