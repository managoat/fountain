### Changed

- The TypeScript SDK no longer claims the REST API is additive (#2669). Its
  changelog and the
  [SDK page](https://managoat.com/docs/sdk#versions-and-compatibility) state
  the policy instead: an SDK major follows each server release that removes
  or changes what the SDK exposes, an older major has no support window, and
  a breaking API change is announced under **Upgrade notes** in the server
  release that makes it.
