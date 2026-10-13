### Upgrade notes

- **`/` redirects to the console, and `/start`, `/terms` and `/privacy` are
  gone** (#2633). Unset `MARKETING_SITE`, `LEGAL_ENTITY`,
  `LEGAL_CONTACT_EMAIL`, `LEGAL_JURISDICTION`, `LEGAL_EFFECTIVE_DATE` and
  `UNVERIFIED_PRUNE_EXEMPT`; nothing reads them. A `BRAND_ASSETS_URL` bundle
  no longer needs `mark-mono.png`.

### Removed

- The verified landing at `/start` and the onboarding stamp (#2633).
  Verification and an OAuth signup land on `/dashboard`.
  `GET /api/account/onboarding` and `POST /api/account/onboarding/complete`
  are removed, `onboarding_completed` leaves `GET /api/auth/me`, and
  `onboarding_completed_at` leaves the admin user views.
- The welcome email, and the daily sweep that deleted accounts left
  unverified for thirty days (#2633).
- The legal pages and the marketing-site links in the manual's header and
  footer (#2633).
