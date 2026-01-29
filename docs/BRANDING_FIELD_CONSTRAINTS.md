# Active Caller Identity Field Constraints & Image Caching

## Field Length Constraints

### Database Constraints

All Active Caller Identity fields have minimum and maximum length constraints enforced at the database level:

| Field | Type | Min Length | Max Length | Notes |
|-------|------|------------|------------|-------|
| `phone_number_e164` | TEXT (NOT NULL) | 1 char | 20 chars | E.164 format (e.g., +1234567890) |
| `brand_name` | TEXT (NOT NULL) | 1 char | 100 chars | Display name shown during incoming calls |
| `logo_url` | TEXT (nullable) | 1 char | 2048 chars | URL to identity image/logo |
| `call_reason` | TEXT (nullable) | 1 char | 200 chars | Optional call reason text |

### Validation Rules

- **phone_number_e164**: Must follow E.164 format (starts with +, followed by country code and number)
- **brand_name**: Required field, cannot be empty
- **logo_url**: Optional, but if provided must be a valid URL (max 2048 chars - standard URL length limit)
- **call_reason**: Optional, can be null

## Image Caching

### Yes, Images Are Stored Locally

The SDK automatically caches identity images locally on the device for instant retrieval during incoming calls.

### iOS Implementation

- **Storage Location**: App's cache directory (`Library/Caches/SecureNodeBranding/`)
- **Format**: PNG files
- **Naming**: Base64-encoded URL (sanitized) with `.png` extension
- **Cache Strategy**: 
  - Check local cache first (instant lookup)
  - If not cached, download from URL and save locally
  - Subsequent lookups use cached image

### Android Implementation

- **Storage Location**: App's cache directory (`cache/SecureNodeBranding/`)
- **Format**: PNG files
- **Naming**: Base64-encoded URL (sanitized) with `.png` extension
- **Cache Strategy**:
  - Check local cache first (instant lookup)
  - If not cached, download asynchronously using OkHttp
  - Save to cache for future use

### Benefits of Local Image Caching

1. **Instant Display**: No network delay when incoming call arrives
2. **Offline Support**: Works even when device is offline
3. **Reduced Bandwidth**: Images downloaded once, reused many times
4. **Better UX**: Caller identity appears immediately without a loading spinner

### Cache Management

- Images are automatically cached when branding data is synced
- Cache persists across app restarts
- Cache can be cleared manually if needed (SDK provides method)
- Old/unused images can be cleaned up periodically

## API Response Format

The sync API returns minimal data optimized for mobile storage:

```json
{
  "branding": [
    {
      "phone_number_e164": "+1234567890",
      "brand_name": "Acme Corp",
      "logo_url": "https://example.com/logo.png",
      "call_reason": "Order update",
      "updated_at": "2024-01-01T12:00:00Z"
    }
  ],
  "synced_at": "2024-01-01T12:00:00Z"
}
```

## Field Usage Examples

### Valid Examples

```javascript
// Valid brand_name (within limits)
brand_name: "Acme Corporation"  // 17 chars ✓

// Valid logo_url (within limits)
logo_url: "https://example.com/logo.png"  // 28 chars ✓

// Valid call_reason (within limits)
call_reason: "Your order is ready for pickup"  // 33 chars ✓

// Valid phone_number_e164
phone_number_e164: "+1234567890"  // 12 chars ✓
```

### Invalid Examples

```javascript
// Invalid: brand_name too long
brand_name: "A".repeat(101)  // 101 chars ✗ (exceeds 100 char limit)

// Invalid: logo_url too long
logo_url: "https://" + "x".repeat(2049)  // 2057 chars ✗ (exceeds 2048 char limit)

// Invalid: call_reason too long
call_reason: "A".repeat(201)  // 201 chars ✗ (exceeds 200 char limit)

// Invalid: phone_number_e164 too long
phone_number_e164: "+" + "1".repeat(20)  // 21 chars ✗ (exceeds 20 char limit)
```

## Notes

- Field constraints are enforced server-side. If you exceed limits, the portal/API may reject the update.
- Devices should treat missing fields as normal (e.g. no logo or no call reason).

