### Upgrade notes

- **Releases no longer publish `-core` image tags** (#2620). Fountain has no
  extensions left, so the bundled and core images are the same server and a
  release publishes one image under `vX.Y.Z` and `vX.Y`. A `-core` tag you
  pinned keeps working but gets no new versions; move to the tag without the
  suffix to upgrade. The `BUNDLE_EXTENSIONS` build argument is gone.

### Removed

- The first-party extension mechanism (ADR 0043) is removed (#2620). No
  extension implemented it any more. An unknown `/api` path still answers
  `404` JSON after authentication.
