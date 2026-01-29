# SecureNode Mobile API — 1‑page quickstart

## Base URL + auth

- **Base URL**: `https://verify.securenode.io`
- **Auth**: send `X-API-Key: <apiKey>` on every request

## The minimal SDK flow (recommended)

### 1) Sync (required)

- **GET** `/api/mobile/branding/sync`
- **Goal**: download the active branding directory and cache it locally
- **Query (optional)**:
  - `since` (ISO-8601) — incremental updates
  - `device_id` — stable device identifier (helps fleet ops/debug policy)

**SDK rule**: treat the local cache as the source of truth at ring-time (offline-first).

### 2) Match + display (local only)

- On incoming call: normalize the caller to E.164 and look it up in the local cache.
- If there’s a local record, show `brand_name` (and `logo_url` / `call_reason` if your call surface supports it).

**SDK rule**: do not block the call UI on network.

### 3) Usage reporting (billable)

When identity is displayed, report the outcome using the event endpoint:

```bash
curl -X POST 'https://verify.securenode.io/api/mobile/branding/event' \
  -H 'X-API-Key: YOUR_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "phone_number_e164": "+1234567890",
    "outcome": "displayed",
    "surface": "display",
    "displayed_at": "2024-01-01T12:00:00Z"
  }'
```

**Expected response:**

```json
{
  "success": true,
  "event_id": "uuid-here",
  "displayed_at": "2024-01-01T12:00:00Z"
}
```

The SDK sends the above fields and may include **device_id**, **event_key** (for idempotency), and **meta** (e.g. **branded**: true, **branding_applied**: true when branding was displayed).

## Optional endpoints

- **Lookup (fallback)**: `GET /api/mobile/branding/lookup?e164=...`
  - Only use when a cache miss happens and you want a best-effort network lookup.

## Gotchas (keep it simple)

- **Always use HTTPS** (redirects can drop headers in some clients).
- **Cache is authoritative at ring-time**: sync periodically and rely on local match.
- **Don’t store API keys in logs**: treat them like passwords.

