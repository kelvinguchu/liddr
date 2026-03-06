# Ride Message Moderation

This document defines the moderation behavior for in-ride chat messages.

## Endpoints
- `GET /api/rides/messages/quick-actions`
- `GET /api/rides/:ride_id/messages`
- `POST /api/rides/:ride_id/messages`
- `POST /api/rides/:ride_id/messages/:id/read`
- `POST /api/rides/:ride_id/messages/:id/hide`
- `POST /api/rides/:ride_id/messages/:id/report`

## Behavior
- Message reporting writes a normal moderation report (`context_type=ride`, `context_reference=ride_message:<id>`).
- Reported messages are soft-hidden for the reporting user.
- Repeated reports against the same sender trigger auto-escalation:
  - apply `user_enforcements` record with `scope=communication`, `action=feature_restriction`
  - create a system moderation signal report (`context_reference=message_abuse_signal:<user_id>`)
- Users with active communication restrictions cannot send ride messages.

## Policy Keys
- `RIDE_MESSAGE_REPORT_WINDOW_DAYS`
- `RIDE_MESSAGE_AUTO_RESTRICT_THRESHOLD`
- `RIDE_MESSAGE_SIGNAL_COOLDOWN_DAYS`
