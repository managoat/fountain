### Changed

- Swift SDK: `LogEvent` is generated from the contract rather than handwritten
  (#2269). Property names, types and optionality are unchanged — including
  `durationMS`, `conversationID` and `agentID` — and `stageData` is unchanged.
  `Block`, `PermissionOption` and `PermissionRequest` stay handwritten by
  design; `contributing/swift-wire-models.md` records why for each.
