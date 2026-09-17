### Fixed

- **A prompt that wakes a parked conversation keeps its images** (#2373).
  `POST /api/conversations/{id}/prompts` accepts `images`, and a conversation
  with a live server got them. One with no server — parked, or in the gap
  after a deploy — was woken first, and the wake delivered the prompt text
  without them: the turn opened with no images while the request answered
  `200 {"status":"queued"}` and the `conversation.prompted` audit row recorded
  the real `image_count`. Both roads now carry the images to the turn.
