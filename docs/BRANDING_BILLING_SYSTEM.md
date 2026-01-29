# Active Caller Identity Billing

## Overview

SecureNode tracks and charges for **Active Caller Identity** based on **delivery effort**.
That means billing is derived from **successful sync deliveries** (what the server successfully delivered to devices),
not from client-side UI confirmations.

## How Usage Is Reported

### Billing signal (authoritative)

Billing is computed from successful calls to:

```
GET /api/mobile/branding/sync
```

The server records each successful sync as a metered delivery event internally.

### Database Tracking

Usage is aggregated server-side from metered delivery events for the billing period.

## Billing Fee Types

### 1. Readiness Fee (monthly subscription)

- **Type**: Recurring, monthly
- **Charged**: Once per month per customer
- **Setting**: `pricing_plans.readiness_fee_cents` (override: `companies.readiness_fee_override_cents`)

### 2. Imprint Overage Fee (per imprint after included)

- **Type**: Usage-based, per imprint
- **Charged**: Only after included imprints are consumed for the month
- **Tracking**: Metered delivery units from `sdk_events` (branding_sync)
- **Setting**: `pricing_plans.overage_fee_microcents_per_imprint` (override: `companies.overage_fee_override_microcents_per_imprint`)
- **Allowance**: `pricing_plans.included_imprints` (override: `companies.included_imprints_override`)

### 3. Number Registration Fee (one-time)

- **Type**: One-time, per number
- **Charged**: When a phone number is first registered (one-time line item)
- **Setting**: `pricing_plans.number_registration_fee_cents`

### Manual Integration Fees (contracted)

- Integration fees are manual invoice items added by admins (not auto-metered).

## Billing Calculation Flow

1. **Period Selection**: User selects billing period (monthly/weekly/daily)
2. **Data Collection**:
   - Count phone numbers registered in period
   - Sum branding sync delivery units in period
   - Apply included imprints allowance (monthly)
   - Apply monthly readiness fee
3. **Fee Calculation**:
   - Registration fees = `numbers × registration_fee`
   - Overage fees = `max(0, imprints - included) × overage_fee`
   - Readiness fee = `1 × readiness_fee` (per month)
4. **Invoice Generation**: All fees combined into line items

## API Endpoints

### Mobile Device Endpoints

- `GET /api/mobile/branding/sync` - Sync Active Caller Identity data to device cache (authoritative billing signal)
- `GET /api/mobile/branding/sync` - Sync Active Caller Identity data to device cache
- `GET /api/mobile/branding/lookup?e164=+1234567890` - Lookup identity for a single number (fallback)

### Optional telemetry (not required for billing)

- `POST /api/mobile/branding/event` - Outcome telemetry (optional; used for analytics/debugging)

### Billing Endpoints

- `GET /api/billing/breakdown` - Get billing breakdown by period
- `GET /api/billing/invoice` - Generate monthly invoice
- `GET /api/billing/pricing` - Get current pricing (plan + overrides)

### Admin Endpoints

- `GET /api/admin/pricing/plans` - List plan defaults
- `PATCH /api/admin/pricing/plans/{plan_code}` - Update plan defaults
- `POST /api/admin/billing/reconcile` - Preview or reconcile Stripe billing

## Configuration

### pricing_plans
Stores plan defaults:
```sql
- plan_code (TIER_A | TIER_B | TIER_C)
- readiness_fee_cents
- included_imprints
- overage_fee_microcents_per_imprint
- number_registration_fee_cents
```

Default plan values (overage in microcents):

- `TIER_C`: readiness_fee_cents=3500, included_imprints=5000, overage_fee_microcents_per_imprint=120000, number_registration_fee_cents=19900
- `TIER_B`: readiness_fee_cents=5500, included_imprints=15000, overage_fee_microcents_per_imprint=98000, number_registration_fee_cents=19900
- `TIER_A`: readiness_fee_cents=7500, included_imprints=25000, overage_fee_microcents_per_imprint=87600, number_registration_fee_cents=19900

### companies (overrides)
Per-customer overrides (nullable):
```sql
- active_plan_code
- included_imprints_override
- overage_fee_override_microcents_per_imprint
- readiness_fee_override_cents
```

### company_invoice_items (manual fees)
Admin-added invoice items (e.g., integration fees):
```sql
- company_id
- category ('integration_fee')
- description
- amount_cents
- occurred_at
- billed_at
```

## Admin Configuration

Admins configure plan defaults via the pricing plans admin API.
Per-customer overrides are stored on the company record.

## Stripe Configuration

Required environment variables:

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_READINESS_PRICE_ID_TIER_A`
- `STRIPE_READINESS_PRICE_ID_TIER_B`
- `STRIPE_READINESS_PRICE_ID_TIER_C`
- `STRIPE_IMPRINTS_PRICE_ID_TIER_A`
- `STRIPE_IMPRINTS_PRICE_ID_TIER_B`
- `STRIPE_IMPRINTS_PRICE_ID_TIER_C`
- `STRIPE_NUMBER_REGISTRATION_PRICE_ID`
- `STRIPE_USAGE_SYNC_SECRET` (manual trigger) or `CRON_SECRET` (Vercel Cron)

Usage reconciliation:

- `GET/POST /api/stripe/report-usage?dry_run=1` to preview
- `GET/POST /api/stripe/report-usage` to apply
- `GET/POST /api/admin/billing/reconcile?dry_run=1` for admin preview

Number registration fees are tracked per number via `phone_numbers.registration_fee_billed_at`
to avoid double-charging.

Integration fees are manual invoice items and are not auto-submitted to Stripe by reconcile.

## Customer Billing View

Customers can view their billing in the Billing page:
- **Billing Breakdown**: Shows fees by period with totals
- **Monthly Invoice**: Detailed invoice with line items

The breakdown shows:
- Registration fees
- Readiness fees
- Overage fees (per imprint after included)
- Included imprints (non-billable)
- Total charges

