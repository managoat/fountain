### Added

- **A conversation can run a different model from its agent** (ADR 0061).
  Name one with `model` on `POST /api/conversations`, or change it on a
  running conversation with `POST /api/conversations/{id}/reapply`. The next
  turn runs on the new model and continues the same runtime session; `null`
  returns to the agent's model. A model the runtime cannot run is
  `422 model_invalid`, and one the conversation's credential does not serve is
  `409 inference_source_changed`. The conversation object reports the override
  as `model`, the four SDKs' `reapply` helpers take it, and `fountain acp`
  reports it on `session/load`. See
  [Change the model](https://managoat.com/docs/api#change-the-model).
