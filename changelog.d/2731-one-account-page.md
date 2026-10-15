### Changed

- The console's account settings are one page at `/account` (#2731), in
  four sections that stay collapsed until you open them: **API keys**,
  **OAuth apps**, **Change password** and **Delete account**. A newly
  created API key stays on screen until you dismiss it, even if you fold its
  section away. A password change comes back to `/account` with its outcome
  shown in that section. The sidebar's **API keys**, **OAuth apps** and
  **Security** links are gone.

### Upgrade notes

- **`/api-keys`, `/account/oauth-apps` and `/account/security` redirect to
  `/account`** (#2731), with the matching section open
  (`/account?open=api-keys`, `?open=oauth-apps`, `?open=password`). Old
  bookmarks keep working. `POST /account/security/password` is unchanged.
