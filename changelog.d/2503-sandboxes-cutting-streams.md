### Added

- **`/admin/broker` lists sandboxes that keep cutting streamed replies**
  (#2503). Some Sprites machines drop any connection that is quiet for about
  a second, so every model reply that pauses is cut and the broker records it
  as `client_closed`. The new Sandboxes cutting streams section lists each
  sandbox with at least 10 requests of one second or longer in the window,
  at least half of them cut, with its owner and the counts. Healthy streams
  end that way less than 1% of the time. Fountain still does not reset such
  a sandbox by itself; see
  [A Sprites machine that drops quiet connections](https://managoat.com/docs/concepts/sandboxes#a-sprites-machine-that-drops-quiet-connections).
