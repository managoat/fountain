### Fixed

- Raw stdout/stderr containing invalid UTF-8 or NUL bytes no longer crashes
  the conversation server. Unrepresentable bytes are shown as `?`; a Unicode
  character split across log rows is replaced in each row (#2372).
