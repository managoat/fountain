### Upgrade notes

- **Migration `20261015230000` drops `sandboxes.woken_at`** (#2721 follow-up).
  No release since the column stopped being mapped reads it; take this
  release only after the one before it is fully rolled out.
