# Liddr Communication Policy (V1)

Last updated: March 4, 2026

## Scope

This policy applies to ride and Send lifecycle communication events:
- ride assignment and status updates
- arrival/start/complete events
- Send pickup/dropoff/recipient confirmation events
- moderation and integrity notices shown inside the app

## Decision

Liddr V1 is **in-app communication first and only** for product lifecycle events.

- No SMS fallback for ride/send lifecycle communication.
- No external token-link confirmation flow for Send recipients.
- Recipient confirmation is done via authenticated in-app endpoint only.

## Exception: Authentication Bootstrap

Phone OTP is an authentication method and not lifecycle communication.

- `phone_otp` may still use SMS for account login/verification bootstrap.
- If product decides to go fully app-bound auth, remove `phone_otp` and keep email/TOTP/social methods.

## Engineering Rule

When implementing new ride/delivery notifications:
- use realtime socket + in-app notification persistence.
- do not add SMS side channels or fallback paths.
