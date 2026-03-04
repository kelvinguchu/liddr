# Ratings V1.5 Roadmap

This file lists post-V1 rating hardening features. It is intentionally not enabled in V1 to avoid false positives before enough marketplace data exists.

## 1. Rater Reliability
- Add per-user `rater_reliability_score`.
- Down-weight ratings from accounts with strong abuse signals.
- Keep raw ratings for audit, but optionally exclude from score impact.

## 2. Serial Low-Rater Quarantine
- Detect users who issue unusually frequent low ratings over rolling windows.
- Mark ratings as `quarantined` (stored, auditable, limited score impact).
- Require ops review for repeated quarantine cases.

## 3. Retaliation Pattern Detection
- Detect suspicious two-way low-rating sequences on the same ride pair.
- Add retaliatory suspicion flags without auto-penalties.
- Feed only into moderation queue unless confidence is high.

## 4. Rating Velocity Anomaly Detection
- Identify sudden bursts of perfect or low ratings outside normal baseline.
- Trigger ops alerts and optional temporary down-weighting.
- Add category/city-specific baselines to reduce false positives.

## 5. Ops Rating Review Console
- Review and nullify ratings with required reason code and note.
- Full audit trail: actor, timestamp, previous/new values.
- Search by ride, user, and anomaly flags.

## 6. Enforcement Readiness Gates
- Keep enforcement off for low sample sizes.
- Introduce minimum recent-volume gates for automated actions.
- Use gradual policy rollout via feature flags per city/category.
