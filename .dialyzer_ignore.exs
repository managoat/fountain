# Dialyzer warnings that are understood and deliberately kept, each with its
# reason. Entries are {file, warning_type, location}.
#
# **Prefer `@dialyzer {:nowarn_function, name: arity}` beside the function.**
# A location pin here is only stable while nothing above it in the file moves.
# The two `conversation_server.ex` entries that used to live here pinned a
# guard near the bottom of a 1400-line module, and they moved three times
# during the #540 audit campaign (1339 -> 1341 -> 1404 -> 1406). Each time the
# build failed with "Unnecessary Skips: 1", which reads like a suppression that
# is no longer needed rather than "you inserted lines above it" — so the real
# error underneath was the second thing you looked at, not the first. They are
# now a `@dialyzer` attribute on `fountain_callback_env/1`: it travels with the
# code, is visible to whoever edits that code, and is still far narrower than a
# file-wide skip.
#
# Reach for this file when the warning has no single owning function — a
# module-level or cross-function inference — or when the code is somewhere you
# cannot put an attribute.
#
# Entries are pinned to a location so a new warning of the same class elsewhere
# in the file still fails the build. dialyxir matches the
# location term exactly as dialyzer reports it: a bare line number when there
# is no column, a {line, column} tuple when there is. A stale entry shows up as
# an "unnecessary skip" in `mix dialyzer --list-unused-filters`.
[
  # Empty since managoat_broker graduated (#1345): the two x509 unknown_type
  # entries that lived here moved to that repository's own ignore file with
  # the package. With them still listed here dialyzer reported
  # "Unnecessary Skips: 2".
]
