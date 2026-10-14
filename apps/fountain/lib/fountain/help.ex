defmodule Fountain.Help do
  @moduledoc """
  The canonical list of in-app help topics.

  There used to be two hand-maintained copies — one in `HelpLive.Show`, one in
  `LlmsController` — with a comment on the second saying "keep them in sync".
  They were not in sync: the LiveView was missing `secrets-managers` and the
  controller was missing `skills`, so `/llms.txt` advertised a URL that flashed
  "No such help topic" and redirected, while the in-app nav hid a page that
  `/llms-full.txt` served in full.

  One list, and a test that checks it against `priv/help/` in both directions,
  so a new topic file with no entry (or an entry with no file) fails rather than
  drifting.
  """

  @topics [
    {"quickstart", "Quickstart"},
    {"agents", "Agents"},
    {"skills", "Skills"},
    {"environments", "Environments"},
    {"vaults", "Vaults"},
    {"manifest", "Manifest"},
    {"spawning", "Spawning sub-agents"},
    {"api", "API reference"},
    {"secrets-managers", "Secrets managers"},
    {"for-llms", "For LLMs"},
    {"runbook", "Operating"}
  ]

  @doc "`{slug, title}` pairs, in nav order."
  @spec topics() :: [{String.t(), String.t()}]
  def topics, do: @topics

  @doc "Just the slugs."
  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(@topics, &elem(&1, 0))

  @doc "Absolute path to the directory holding the topic markdown."
  @spec dir() :: String.t()
  def dir, do: Path.join(:code.priv_dir(:fountain) |> to_string(), "help")

  @doc "Markdown files present on disk, as slugs. The other half of the check."
  @spec files() :: [String.t()]
  def files do
    dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.map(&Path.rootname/1)
    |> Enum.sort()
  end
end
