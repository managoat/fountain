defmodule Fountain.PublicUrlTest do
  @moduledoc """
  Regression cover for the FOUNTAIN_DOMAIN defect: the variable was used both
  as a bare host (endpoint) and as an absolute base URL (email links,
  FOUNTAIN_BASE_URL in sprites), and every shipped example sets it bare — so
  every generated link came out schemeless.
  """

  # async: false — `describe "base/0"` writes the global `:public_url`, which
  # the rest of the suite reads. The same write in `user_emails_test.exs` was failing every (since removed) `og:url`
  # assertion in the suite on some seeds; this module holds it for a much
  # shorter window and was never caught doing it, which is not a reason to
  # keep it in the async set.
  use ExUnit.Case, async: false

  doctest Fountain.PublicUrl

  alias Fountain.PublicUrl

  describe "absolute/2" do
    test "adds the scheme to a bare host — the shape every deploy example uses" do
      assert PublicUrl.absolute("fountain.inevitable.fyi", "https") ==
               "https://fountain.inevitable.fyi"
    end

    test "leaves an already-absolute URL alone" do
      assert PublicUrl.absolute("https://example.com", "https") == "https://example.com"
      assert PublicUrl.absolute("http://localhost:4000", "https") == "http://localhost:4000"
    end

    test "honours the requested scheme for bare hosts" do
      assert PublicUrl.absolute("example.com", "http") == "http://example.com"
    end

    test "strips a trailing slash so callers can concatenate paths" do
      assert PublicUrl.absolute("https://example.com/", "https") == "https://example.com"
      assert PublicUrl.absolute("example.com/", "https") == "https://example.com"
    end

    test "falls back to the dev default when unset or blank" do
      assert PublicUrl.absolute(nil, "https") == "http://localhost:4000"
      assert PublicUrl.absolute("", "https") == "http://localhost:4000"
      assert PublicUrl.absolute("   ", "https") == "http://localhost:4000"
    end

    test "keeps a port" do
      assert PublicUrl.absolute("example.com:8080", "https") == "https://example.com:8080"
    end
  end

  describe "host/1" do
    test "extracts the bare host from an absolute URL" do
      assert PublicUrl.host("https://fountain.inevitable.fyi") == "fountain.inevitable.fyi"
    end

    test "passes a bare host straight through" do
      assert PublicUrl.host("fountain.inevitable.fyi") == "fountain.inevitable.fyi"
    end

    test "drops the port, which check_origin and endpoint :url set separately" do
      assert PublicUrl.host("https://example.com:8080") == "example.com"
    end

    test "falls back to localhost when unset" do
      assert PublicUrl.host(nil) == "localhost"
      assert PublicUrl.host("") == "localhost"
    end
  end

  describe "base/0" do
    test "normalises whatever is in app env, even if set bare" do
      original = Application.get_env(:fountain, :public_url)
      on_exit(fn -> Application.put_env(:fountain, :public_url, original) end)

      Application.put_env(:fountain, :public_url, "fountain.example.com")
      assert PublicUrl.base() == "https://fountain.example.com"
    end
  end
end
