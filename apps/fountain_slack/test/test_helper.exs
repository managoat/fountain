# This app's tests run in the umbrella's VM alongside Fountain's, against the
# same Repo and the same SQL Sandbox. `mix test` at the root starts every app,
# so ExUnit.start/0 here is a no-op when Fountain's helper ran first and the
# entry point when this app's suite is run alone.
ExUnit.start()

if Process.whereis(Fountain.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :manual)
end

# The schema guard (#1427) validates every rendered response against the schema
# its operation declares. It is attached from `apps/fountain`'s helper for a
# root `mix test`, and again here because `scripts/test-libraries.sh` runs this
# suite from this directory, where that helper never runs. `attach/0` is
# idempotent: `:telemetry.attach/4` with the same id replaces the handler, and
# the second ETS keeper finds the table already there. Without it this app's
# own suite would be the one place an extension's responses go unchecked
# (#1536).
FountainWeb.SchemaGuard.attach()
