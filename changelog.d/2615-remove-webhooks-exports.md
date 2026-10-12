### Upgrade notes

- **Outbound webhooks and the account data export are removed** (#2615).
  `/api/webhooks`, `/account/webhooks`, `/api/account/exports` and the export
  download answer `404`, `fountain webhooks` is gone, and a manifest naming
  the `Webhook` kind is refused. A migration drops `account_exports` and
  deletes pending webhook and export jobs; the webhook tables stay until a
  later release drops them. `WEBHOOKS_ENABLED` and `WEBHOOK_ALLOW_HTTP` are
  no longer read. Account deletion is unchanged.

### Removed

- Outbound webhooks: endpoints, signed deliveries, the delivery log, the
  switched-off email, the console page, the `fountain webhooks` commands, the
  `Webhook` manifest kind and its signing secret on apply results, and the
  webhooks reference page (#2615).
- The account data export, from the API and from the `/account` page (#2615).
