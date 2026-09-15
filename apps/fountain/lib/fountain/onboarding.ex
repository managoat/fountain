defmodule Fountain.Onboarding do
  @moduledoc """
  The first request, in one place (ADR 0038 decision 5).

  Onboarding is a key and one request. The request the verified landing hands
  over (`FountainWeb.StartLive`) and the request `docs/quickstart.md` prints
  have to be the same text, or the developer who reads both learns that one of
  them is wrong. So there is one source for it, and it is a pair of files:

    * `docs/snippets/first-request.sh` — the `curl`
    * `docs/snippets/first-request.ts` — the TypeScript SDK equivalent

  The docs include those files verbatim (`--8<--`, the same mechanism
  `docs/changelog.md` and `docs/tour.md` use) with their placeholders intact,
  because a reader of the manual has no key yet. This module reads the same
  two files at compile time and substitutes the placeholders, because a reader
  of the landing page does.

  They live under `docs/` deliberately. Anything `Fountain.Docs` reads at
  compile time must be `COPY`d into the Docker build stage or `mix release`
  dies and the deploy silently never happens (#884), and `COPY docs ./docs` is
  already in the Dockerfile. A snippet under `examples/` would have needed a
  second `COPY` line and a second thing to remember.

  ## Placeholders

  | Token | Becomes |
  |---|---|
  | `$FOUNTAIN_BASE_URL` | this instance's public URL |
  | `$FOUNTAIN_API_KEY` | the key the landing just minted |
  | `$FOUNTAIN_AGENT_ID` | the agent the request runs against |
  | `new Fountain()` | `new Fountain({apiKey, baseUrl})`, since a copied snippet has no environment |

  The shell snippet keeps environment variables rather than inlining anything,
  so what the manual prints and what the page prints differ only in the values
  a reader could not have known.
  """

  @root Path.expand("../../../..", __DIR__)
  @sh_path Path.join(@root, "docs/snippets/first-request.sh")
  @ts_path Path.join(@root, "docs/snippets/first-request.ts")

  @external_resource @sh_path
  @external_resource @ts_path

  @curl @sh_path |> File.read!() |> String.trim_trailing()
  @typescript @ts_path |> File.read!() |> String.trim_trailing()

  # The one prompt. It asks for something every sandbox can answer with no
  # repository, no token and no setup script, which is the whole point: the
  # shortest documented path used to need a GitHub token, and an account that
  # has to fetch one before anything replies is an account that leaves.
  @prompt "Which operating system and working directory are you in? Answer in one sentence."

  @doc "The prompt both snippets send."
  @spec prompt() :: String.t()
  def prompt, do: @prompt

  @doc "The `curl`, with its placeholders left in — what the manual prints."
  @spec curl_template() :: String.t()
  def curl_template, do: @curl

  @doc "The TypeScript, with its placeholders left in — what the manual prints."
  @spec typescript_template() :: String.t()
  def typescript_template, do: @typescript

  @doc """
  The `curl` for a real key and a real agent.

  Options: `:base_url`, `:api_key`, `:agent_id`. Anything not given keeps its
  placeholder, so a page with no agent yet still renders something honest.
  """
  @spec curl(keyword()) :: String.t()
  def curl(opts \\ []) do
    @curl
    |> replace("$FOUNTAIN_BASE_URL", opts[:base_url])
    |> replace("$FOUNTAIN_API_KEY", opts[:api_key])
    |> replace("$FOUNTAIN_AGENT_ID", opts[:agent_id])
  end

  @doc """
  The TypeScript for a real key and a real agent.

  Options: `:base_url`, `:api_key`, `:agent_id`. A copied snippet runs in a
  terminal that has never heard of this account, so the bare `new Fountain()`
  the manual shows — which reads `FOUNTAIN_API_KEY` from the environment, as
  the CLI does — becomes an explicit constructor here.
  """
  @spec typescript(keyword()) :: String.t()
  def typescript(opts \\ []) do
    @typescript
    |> replace("$FOUNTAIN_AGENT_ID", opts[:agent_id])
    |> constructor(opts[:api_key], opts[:base_url])
  end

  @doc """
  Every placeholder token these snippets carry.

  `onboarding_test.exs` asserts that a fully-substituted render contains none
  of them: a token that survives is a token the developer pastes into their
  terminal.
  """
  @spec placeholders() :: [String.t()]
  def placeholders do
    ~w($FOUNTAIN_BASE_URL $FOUNTAIN_API_KEY $FOUNTAIN_AGENT_ID)
  end

  @doc """
  The placeholders still present in `text`, in `placeholders/0` order.

  `GET /api/catalog` answers with this rather than the whole list: the server
  fills the base URL in before it hands the snippet over, so a client told to
  substitute `$FOUNTAIN_BASE_URL` would be looking for a token that is not
  there. What is left is exactly what the caller has and the server does not
  — its own raw key, and the agent it picked.
  """
  @spec remaining_placeholders(String.t()) :: [String.t()]
  def remaining_placeholders(text) when is_binary(text) do
    Enum.filter(placeholders(), &String.contains?(text, &1))
  end

  defp replace(text, _token, nil), do: text
  defp replace(text, token, value), do: String.replace(text, token, to_string(value))

  defp constructor(text, nil, nil), do: text

  defp constructor(text, api_key, base_url) do
    args =
      [{"apiKey", api_key}, {"baseUrl", base_url}]
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> Enum.map_join(", ", fn {k, v} -> ~s(#{k}: "#{v}") end)

    String.replace(text, "new Fountain()", "new Fountain({ #{args} })")
  end
end
