# Liddr Repository Guardrails

These guardrails are mandatory for all Codex sessions in this repository.

## Core Priorities
1. Great UI/UX and intentional product design.
2. Low-latency user experience and backend responsiveness.
3. Strong security and privacy by default.

## Required Baselines
- Always follow `docs/ENGINEERING_BASELINE.md`.
- API work must also follow `api/SECURITY_BASELINE.md` and `api/AGENTS.md`.
- If there is a conflict, choose the stricter security rule.

## Non-Negotiable Rules
- Do not ship placeholder UI or generic boilerplate experiences.
- Do not merge changes that regress responsiveness without an explicit approval.
- Do not bypass authentication, authorization, or auditability for protected flows.
- Do not commit secrets, tokens, keys, or sensitive production data.
- Do not invent API contracts; align docs and clients to implemented routes.
- Follow DRY principles; avoid duplicated logic and duplicated source-of-truth values.
- Keep code files at 250 LOC or less unless there is a clear, documented reason.

## Quality Gate
Before considering work complete:
- UX: verify accessibility basics and visual consistency.
- Latency: verify no obvious hot-path regressions.
- Security: run the relevant security checklist for touched surfaces.
