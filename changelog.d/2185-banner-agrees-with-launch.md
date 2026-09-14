### Fixed

- The verified landing's "no inference credential yet" banner now shows when
  the agent's named credential set is empty on a deployment with a platform
  key, because a launch on that agent is refused rather than sent to the
  platform key; the banner asks the same resolver the launch does (#2185).
