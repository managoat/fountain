defmodule Managoat.Sandbox.Sprites.ClientTest do
  @moduledoc """
  Listing every sprite on the account.

  `Sprites.list/2` pattern-matches the `"sprites"` key out of the response and
  drops `has_more` and `next_continuation_token`, so it returns the first page
  of 50 and gives the caller no way to tell there is more. Against production
  that is 50 names out of 114. Anything that compares that list to the database
  to decide what has leaked would conclude that two thirds of the account does
  not exist — so these tests are mostly about pagination being real.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox.Sprites.Client, as: SpritesClient

  setup :set_mimic_global

  setup do
    previous = Application.get_env(:fountain, Managoat.Sandbox.Sprites, [])
    put_sprites_config(Keyword.merge(previous, token: "test-token"))
    on_exit(fn -> put_sprites_config(previous) end)
    :ok
  end

  defp put_sprites_config(config) do
    Application.put_env(:fountain, Managoat.Sandbox.Sprites, config)
  end

  defp page(names, next \\ nil) do
    %{
      "sprites" => Enum.map(names, &%{"name" => &1}),
      "has_more" => next != nil,
      "next_continuation_token" => next
    }
  end

  defp stub_pages(pages) do
    # Keyed by the continuation token the request carries, so the test asserts
    # the token is actually threaded through rather than just counting calls.
    stub(Req, :get, fn _req, opts ->
      token = opts |> Keyword.get(:params, []) |> Keyword.get(:continuation_token)
      {:ok, %{status: 200, body: Map.fetch!(pages, token)}}
    end)
  end

  test "a single page returns every name" do
    stub_pages(%{nil => page(~w(a b c))})

    assert {:ok, names} = SpritesClient.list_all_names()
    assert names == MapSet.new(~w(a b c))
  end

  test "follows the continuation token across pages" do
    # The regression this file exists for.
    stub_pages(%{
      nil => page(~w(a b), "tok-1"),
      "tok-1" => page(~w(c d), "tok-2"),
      "tok-2" => page(~w(e))
    })

    assert {:ok, names} = SpritesClient.list_all_names()
    assert names == MapSet.new(~w(a b c d e))
  end

  test "stops when has_more is true but no token comes back" do
    # Rather than looping forever on a server that contradicts itself.
    stub_pages(%{nil => %{"sprites" => [%{"name" => "a"}], "has_more" => true}})

    assert {:ok, names} = SpritesClient.list_all_names()
    assert names == MapSet.new(["a"])
  end

  test "refuses to return a partial view rather than a short list" do
    # A caller deciding what to delete must never be handed a truncated set that
    # looks complete — every unlisted sprite would look already destroyed.
    stub(Req, :get, fn _req, opts ->
      token = opts |> Keyword.get(:params, []) |> Keyword.get(:continuation_token)
      next = "tok-#{token}"
      {:ok, %{status: 200, body: page(["sprite-#{token}"], next)}}
    end)

    assert {:error, :truncated} = SpritesClient.list_all_names()
  end

  test "surfaces an API error" do
    stub(Req, :get, fn _req, _opts -> {:ok, %{status: 500, body: "boom"}} end)

    assert {:error, {:api_error, 500, "boom"}} = SpritesClient.list_all_names()
  end

  test "surfaces a transport error" do
    stub(Req, :get, fn _req, _opts -> {:error, :nxdomain} end)

    assert {:error, :nxdomain} = SpritesClient.list_all_names()
  end

  test "raises when no token is configured" do
    put_sprites_config(token: nil)

    assert_raise RuntimeError, ~r/SPRITES_TOKEN is not set/, fn ->
      SpritesClient.list_all_names()
    end
  end
end
