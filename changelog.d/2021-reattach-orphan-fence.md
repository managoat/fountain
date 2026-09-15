### Fixed

- A conversation server reattaching after a restart no longer interrupts a
  turn that is running on a replacement sandbox. Its give-up path now writes
  only while it still holds the conversation's binding (#2021).
