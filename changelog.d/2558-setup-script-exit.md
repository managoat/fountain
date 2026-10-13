### Fixed

- **A setup script's background processes no longer hold the provision**
  (#2558). The setup step ends when the script exits. A process it leaves
  running, such as a dev server started with `&` or a keepalive loop, used to
  keep the step open until it closed its output, which delayed the provision by
  up to 30 s or failed it at the setup timeout. Output a background process
  writes after the script exits no longer reaches the setup log.
