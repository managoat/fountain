# See what sandboxes cost

Every conversation runs in a sandbox, and a sandbox costs money for as long as
it runs. This guide shows you how to read that cost per provider, and how to
say which account it belongs to.

## What Fountain measures

Fountain measures active sandbox time. The clock starts when Fountain creates a
sandbox, because a provider charges from the moment it starts to build one. The
clock stops when the sandbox goes away.

Parked time does not count. A suspended sandbox scales to zero and costs almost
nothing. See
[Change sandbox lifetimes](sandbox-lifetime.md) for what parks a sandbox.

Fountain cuts every number to the period you ask about. A sandbox that spans
the end of a month gives each month the time it ran in that month. A sandbox
that has not stopped gives you the time up to now. This is what makes a month
of Fountain numbers comparable with a month of provider invoices.

## Idle time, and why it is the number to look at

A sandbox that nobody prompts still runs, and a provider still charges full
rate for it. So idle time counts as active time. Fountain also reports it on
its own, because it is the part of the bill you can remove.

Busy time is the time with a turn in flight. Idle time is the rest. Together
they add up to the active hours. Read a card that says 40 hours, 36 of them
idle, as agents that sat at a prompt. The idle timeout is too long. See
[Change sandbox lifetimes](sandbox-lifetime.md) to shorten it.

Two conversations that prompt the same sandbox at the same moment make one
busy sandbox, not two. Fountain counts the overlap once.

## Read it in the admin panel

Sign in as an admin and open `/admin/sandboxes`. The **Spend by provider** panel
shows one card for each provider. Each card gives the active hours, the sandbox
count, how many accounts are behind it, and the idle hours inside that total.
The idle figure turns amber above 50%. Below the cards, **Who it belongs to**
names the accounts with the most hours, each with its own idle share.


The list under the cards is also `GET /api/admin/sandboxes`, for a script.
Read [Admin](../../api.md#admin).


## What each provider means for your bill

| Provider | Who pays |
|---|---|
| `sprites` | You. Time here lands on your Sprites invoice. |
| `e2b` | You. Time here lands on your E2B invoice. |
| `runner` | The account that owns the machine. A [self-hosted runner](../../integrations/runners.md) runs on hardware you do not pay for. |

The **Billable to us** line adds up only the first two. The panel shows
runner hours so the picture is complete. It keeps them out of that total so the
total stays true.


## Watch it live

The Prometheus endpoint exports
`fountain_sandboxes_by_provider_count`, tagged by provider and status. Use it
to see how many sandboxes each provider runs right now. It carries no
account tag, because one time series per account would grow without a bound.
Per-account numbers belong in the admin panel and the API, where they are a
column.

See [Configure observability](observability.md) for how to scrape the endpoint.

## When to distrust the parked figures

Fountain writes a sandbox row synchronously, and cannot lose it. The suspend
and resume records that mark parked time are different. Fountain writes those
best-effort on purpose, because a metering problem must not fail somebody's
conversation. A database problem can drop one.

A dropped suspend record makes parked time look like run time. A dropped
resume record does the opposite. Neither
one is silent. Each drop increments the `fountain_usage_dropped_count` metric.
Read that metric for the period you want. A count above zero says the parked
figures rest on an incomplete record. Treat that period as approximate.

## What these numbers are not

They are hours, not money. Providers price by machine size and by contract, and
Fountain holds no rate card. Multiply the hours by the rate you pay.

They also cover sandboxes only. Model inference runs on your users' own
credentials, or on a platform key whose bill comes from the model provider.

## Related


- [Change sandbox lifetimes](sandbox-lifetime.md), the main lever on the total.
- [About sandboxes](../../concepts/sandboxes.md), for what a sandbox is.
- [Configure observability](observability.md), for the metrics endpoint.
