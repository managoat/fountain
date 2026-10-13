### Changed

- **A refused request no longer closes its connection through the broker**
  (#2503). `managoat_broker` 0.16.0 answers a refused request that has no body
  and keeps the connection open for the next request. A refused request with a
  body still closes it. A sandbox now opens far fewer connections when it
  keeps asking for routes the broker refuses.
