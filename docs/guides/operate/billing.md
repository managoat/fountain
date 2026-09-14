# Start billing

<!-- "billing" is a Technical Name here: the product surface, the
     CREDITS_ENABLED flag and the Elixir context all carry it. STE exempts a
     Technical Name from the -ing rule, and the linter has no vocabulary
     hook for that rule, so the exemption is declared for the page. -->
<!-- vale STE.IngForms = NO -->

This guide shows you how to start billing, and why you probably must not.

## Leave it off unless you run Fountain commercially

Billing is off by default (`CREDITS_ENABLED=false`), and the compose file pins
it off as well. On your own instance it is a meter with no till. Leave it
off, unless you run Fountain commercially and you configured Stripe.

With billing off, no account has a balance and nothing burns. Fountain
refuses nothing. Nothing that looks like billing appears in the UI, in the
admin panel or in the API.

## What billing is

Credits are the product. Each account holds a balance in cents. A new account
starts with `CREDIT_OPENING_CENTS` ($5) for `CREDIT_OPENING_DAYS` (14). Each
turn burns `CREDIT_TURN_HOUR_CENTS` an hour. A tenant buys more credit in
packs. There are no plans and no subscription. See
[Prices](plans-and-prices.md).

A tenant may run as many sandboxes at once as the balance funds, between
`SANDBOX_CAP_FLOOR` and `SANDBOX_CAP_CEILING`, and the whole deployment stops
at `SANDBOX_FLEET_CEILING`. Set the fleet ceiling to what your sandbox
provider plan allows.

## Start it

1. Set the price. `CREDIT_TURN_HOUR_CENTS` defaults to 25.
2. Configure Stripe. The [Stripe integration guide](../../integrations/stripe.md)
   covers `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and the three webhook
   events.
3. Set `CREDITS_ENABLED=true` and deploy. The pricer looks back seven days,
   so it prices the turns from the last week too. Comp or credit the
   accounts you do not want to charge for them.

## Give the accounts you already have their opening credit

An account that verified its email while billing was off holds nothing. It
gets a refusal at the first spend the moment you turn billing on. Give those
accounts the opening credit in the admin panel, or with the admin API:

```bash
curl -X POST "$FOUNTAIN_URL/api/admin/users/$USER_ID/credits" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"cents": 1000, "note": "opening credit, billing started"}'
```

## Verify it worked

Sign in as an account that is not an admin. The billing page shows the
balance and the packs. Start a conversation and wait for the turn to end.
The balance falls at the next run of the pricer, at most ten minutes later.

## Related

- [Stripe integration guide](../../integrations/stripe.md).
- [Prices](plans-and-prices.md).
- [See what sandboxes cost](sandbox-spend.md), for what each account runs and
  which provider you pay for it.
- [Run a release task](run-a-release-task.md).

<!-- vale STE.IngForms = YES -->
