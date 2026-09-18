# Offline correctness regressions for the opt-in live probe's resource cleanup.
# Run: MIX_ENV=test mise exec -- mix run --no-start scripts/sandbox-files/sprites_cleanup_test.exs
unless Mix.env() == :test, do: raise("run with MIX_ENV=test")

{:ok, _} = Application.ensure_all_started(:mimic)
Mimic.copy(Req)
Mimic.copy(Managoat.Sandbox.Sprites)

# Load the real module without executing the script's live entry point.
path = Path.join(__DIR__, "sprites_execution_probe.exs")
{:__block__, _, forms} = Code.string_to_quoted!(File.read!(path))

[definition] =
  Enum.filter(forms, fn form ->
    match?({:defmodule, _, [{:__aliases__, _, [:Fountain, :SpritesExecutionProbe]}, _]}, form)
  end)

Code.eval_quoted(definition, [], file: path)
ExUnit.start(autorun: false, seed: 0)

defmodule Fountain.SpritesCleanupTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO
  alias Managoat.Sandbox.Sprites, as: Adapter

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    previous_token = System.get_env("SPRITES_TOKEN")
    previous_config = Application.fetch_env(:managoat_sandbox, Adapter)
    System.put_env("SPRITES_TOKEN", "offline-placeholder")

    on_exit(fn ->
      if previous_token,
        do: System.put_env("SPRITES_TOKEN", previous_token),
        else: System.delete_env("SPRITES_TOKEN")

      case previous_config do
        {:ok, config} -> Application.put_env(:managoat_sandbox, Adapter, config)
        :error -> Application.delete_env(:managoat_sandbox, Adapter)
      end
    end)

    for method <- [:post, :get, :delete] do
      stub(Req, method, fn _, _ -> flunk("unexpected provider request: #{method}") end)
    end

    stub(Adapter, :build_handle, fn _ -> flunk("probe must not start after bookkeeping fails") end)

    :ok
  end

  for matching_id <- [true, false] do
    test "failed post-create record write: matching resource ID = #{matching_id}" do
      expect(Req, :post, fn _, [url: "/v1/sprites", json: %{name: name}] ->
        record = Path.join(System.tmp_dir!(), name <> ".json")
        on_exit(fn -> File.rm_rf!(record) end)
        assert %{"status" => "create_pending"} = Jason.decode!(File.read!(record))

        # A directory at the record path makes the next real File.write! fail.
        File.rm!(record)
        File.mkdir!(record)
        url = "/v1/sprites/#{name}"

        if unquote(matching_id) do
          expect(Req, :get, 2, fn _, [url: ^url] ->
            if File.dir?(record) do
              send(self(), :identity_checked)
              {:ok, %{status: 200, body: %{"id" => "owned-id"}}}
            else
              send(self(), :absence_checked)
              {:ok, %{status: 404}}
            end
          end)

          expect(Req, :delete, fn _, [url: ^url] ->
            assert_received :identity_checked
            File.rmdir!(record)
            send(self(), {:deleted, record})
            {:ok, %{status: 204}}
          end)
        else
          expect(Req, :get, fn _, [url: ^url] ->
            send(self(), :identity_mismatch)
            {:ok, %{status: 200, body: %{"id" => "different-incarnation"}}}
          end)
        end

        {:ok, %{status: 201, body: %{"id" => "owned-id"}}}
      end)

      capture_io(fn ->
        if unquote(matching_id) do
          error = assert_raise File.Error, fn -> Fountain.SpritesExecutionProbe.run() end
          assert error.reason == :eisdir
        else
          assert_raise MatchError, fn -> Fountain.SpritesExecutionProbe.run() end
        end
      end)

      if unquote(matching_id) do
        assert_received {:deleted, record}
        assert_received :absence_checked
        assert %{"status" => "deleted_verified"} = Jason.decode!(File.read!(record))
      else
        assert_received :identity_mismatch
      end
    end
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 1)
