---
title: "iOS"
description: "our mobile SDK for iOS"
icon: "apple-whole"
---

# Mobile Call Branding System — Image Storage & Field Constraints Summary

This document outlines how the Secure Node Mobile Branding SDK handles image caching, field constraints, database validations, and supporting files generated for the system.

---

## 1. Image Storage — Local Caching on Device

Branding images (logos) are cached locally to ensure:

- Instant display during incoming calls
- Offline functionality
- Reduced network usage
- Smooth, low‑latency rendering inside CallKit / ConnectionService

### iOS Image Caching

- Storage path: `Library/Caches/SecureNodeBranding/`
- Format: PNG
- Logic:
  - Check cache → if exists, load instantly
  - If missing → download → save to cache → return

### Android Image Caching

- Storage path: `cache/SecureNodeBranding/`
- Format: PNG
- Logic:
  - Same as iOS: lookup → download if required → cache

### SDK Components Created

- `ImageCache.swift` for iOS
- `ImageCache.kt` for Android

Both provide:

- `getImage(logoUrl)`
- Automatic caching
- Background image fetch
- Error fallback handling

---

## 2. Field Constraints (Min/Max Values)

All branding data fields have enforced constraints at the database level.

| Field               | Min | Max  | Notes                                              |
| ------------------- | --- | ---- | -------------------------------------------------- |
| `phone_number_e164` | 1   | 20   | Must be valid E.164 (e.g., +1234567890)            |
| `brand_name`        | 1   | 100  | Required. Appears on incoming call UI              |
| `logo_url`          | 1   | 2048 | Optional. Must be valid URL                        |
| `call_reason`       | 1   | 200  | Optional. Short text describing why you're calling |

### Schema Changes Implemented

- Added CHECK constraints to `mobile_device_branding_sync`
- Added constraints to core branding tables (branding_requests, etc.)
- Provided SQL migration file: **`add_branding_field_constraints.sql`**

---

## 3. Active Branding Selection Logic

The device determines which branding profile to display based on:

1. The incoming number (`phone_number_e164`)
2. Lookup in `mobile_device_branding_sync`
3. Filtering for:
   - `is_active = true`
4. If multiple matches exist:
   - Use the **most recently updated** record

### Auto‑sync Behavior

A PostgreSQL trigger updates `mobile_device_branding_sync` whenever:

- A branding request is approved
- Branding metadata is updated

This ensures the device always has the correct branding available locally.

---

## 4. No Data Duplication (Optimised Sync)

The system minimizes bandwidth and avoids redundant data by design.

### Sync Endpoint

`GET /api/mobile/branding/sync?since=<timestamp>`

- Returns only records modified **after** the timestamp
- Ideal for incremental updates
- Payloads include only:
  - `phone_number_e164`
  - `brand_name`
  - `logo_url`
  - `call_reason`
  - `is_active`
  - `updated_at`

### Lookup Endpoint

`GET /api/mobile/branding/lookup?e164=<number>`

- Used only if:
  - Local cache missed
  - First-time caller
  - Corrupted or missing cached data

### Benefits

- Minimal network usage
- Instant in-call branding
- Offline functionality
- Zero duplication across sync cycles

---

## 5. Device-Level Call Branding Service

The SDK integrates with each OS’s native call interception APIs.

---

### iOS — CallKit

The SDK:

- Registers a CallKit extension
- Receives VoIP push notifications before call arrival
- Uses `CXProvider` to present branded caller info
- Loads images and text from the **local SQLite database**

Flow:

1. Incoming call triggers CallKit
2. SDK performs instant DB lookup
3. Call UI shows brand_name + logo + call_reason
4. If not found locally → fallback API lookup

---

### Android — ConnectionService

The SDK:

- Registers a custom `ConnectionService`
- Integrates with Android’s `TelecomManager`
- Applies branding before call UI renders
- Uses **Room database** for instant lookups

Flow:

1. TelecomManager routes call to ConnectionService
2. SDK fetches local branding metadata
3. Branding applied to call screen
4. Fallback → `/lookup` API

---

## 6. Files Created in the System

| File / Component                         | Purpose                                    |
| ---------------------------------------- | ------------------------------------------ |
| `create_mobile_device_branding_sync.sql` | Creates sync table + triggers              |
| `add_branding_field_constraints.sql`     | Adds DB field limits                       |
| `/api/mobile/branding/lookup`            | Fallback lookup endpoint                   |
| `/api/mobile/branding/sync`              | Full or incremental metadata sync          |
| `ImageCache.swift`                       | iOS branding image cache                   |
| `ImageCache.kt`                          | Android branding image cache               |
| `SDKIntegration.tsx`                     | Documentation + example interception logic |
| `BRANDING_FIELD_CONSTRAINTS.md`          | Field limits specification                 |

---

## 7. End-to-End Branding Flow Summary

1. **Branding request approved**\
   → Trigger updates `mobile_device_branding_sync`
2. **Mobile app syncs**\
   → Calls `/api/mobile/branding/sync` to fetch changes
3. **Local storage updated**\
   → SDK saves branding records + logo image cache
4. **Incoming call arrives**\
   → CallKit / ConnectionService notifies SDK
5. **Instant DB lookup**\
   → Retrieves brand_name, logo, call_reason
6. **Branding applied to call UI**
7. **Fallback API lookup** if needed

---

## System Highlights

- Ultra-fast, offline-capable branding
- Minimal bandwidth usage
- Strict field validation and data consistency
- Automatic sync via database triggers
- Native iOS/Android call interception support

---