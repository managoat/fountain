### Added

- **`REGISTRATION_ACCESS_CODE` gates signup behind a shared code.** When it is set, the sign-up form asks for the code, `POST /api/auth/register` refuses a request without it with 403 `access_code_required`, and a first GitHub sign-in needs the code entered on the sign-up page first. Existing accounts sign in as before. Unset, signup is unchanged. See the [configuration reference](https://managoat.com/docs/configuration).
