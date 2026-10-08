### Fixed

- A self-hosted runner whose server stays unreachable keeps waiting 30
  seconds between reconnects (#2599). Before, after about 65 failed attempts
  the delay overflowed to zero, and the runner redialed in a tight loop,
  writing a warning on every try until its log filled the disk.
