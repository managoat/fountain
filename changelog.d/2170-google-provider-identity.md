### Fixed

- Gmail tools reject tenant-defined providers named `google` after the Google
  extension is installed, keeping their credentials out of Gmail requests (#2170).
- Tenant-defined Google providers keep remote-server setup instructions after
  extension installation, and their accounts can coexist with platform Google
  accounts using the same label. Reconnecting updates only that provider's grant
  (#2170).
