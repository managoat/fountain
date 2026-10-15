defmodule Managoat.Sandbox.SpritesPublicUrlsTest do
  # Moved out of Managoat.Sandbox.SpritesTest, which is `async: true`: this
  # writes the adapter's application env, which is global, so it runs on its
  # own after the async modules (see async_global_config_guardrail_test.exs).
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.Sprites, as: Adapter

  @name "fountain-abc12345-deadbeef"

  setup :set_mimic_global

  setup do
    previous = Application.get_env(:fountain, Managoat.Sandbox.Sprites, [])

    Application.put_env(
      :fountain,
      Managoat.Sandbox.Sprites,
      Keyword.merge(previous, public_urls: false)
    )

    on_exit(fn -> Application.put_env(:fountain, Managoat.Sandbox.Sprites, previous) end)
    :ok
  end

  test "leaves the URL alone when public URLs are switched off" do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test-token"} end)
    stub(Sprites, :create, fn _client, @name, [] -> {:ok, %Sprites.Sprite{name: @name}} end)

    stub(Sprites, :update_url_settings, fn _sprite, _settings ->
      flunk("should not be called")
    end)

    assert {:ok, %Handle{}} = Adapter.create(@name, [])
  end

  test "fresh creation keeps URL access private in its only provider request" do
    owner = self()

    req =
      Req.new(
        base_url: "https://provider.invalid",
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 201, Jason.encode!(%{name: @name, id: "new-instance"}))
        end
      )

    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)

    assert {:ok, %Handle{instance_id: "new-instance"}} = Adapter.create_new(@name, [])

    assert_receive {:body,
                    %{"url_settings" => %{"auth" => "sprite"}, "wait_for_capacity" => false}}

    refute_receive {:body, _}
  end
end
