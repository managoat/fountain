defmodule Fountain.EnvironmentLayers.EnvelopeTest do
  use Fountain.DataCase, async: true

  alias Fountain.EnvironmentLayers.Envelope

  setup do
    user = insert_verified_user()
    env = insert_env(%{user_id: user.id})
    artifact = Ecto.UUID.generate()

    binding = %{
      "version" => 1,
      "user" => user.id,
      "environment" => env.id,
      "fingerprint" => String.duplicate("a", 64),
      "provider" => "sprites",
      "architecture" => "amd64",
      "base" => "immutable-base-123"
    }

    %{user: user, env: env, artifact: artifact, binding: binding}
  end

  test "wraps one identity and binds all compatibility metadata", ctx do
    identity = "AGE-SECRET-KEY-1TEST-IDENTITY"

    assert {:ok, wrapped} =
             Envelope.wrap(ctx.user.id, ctx.env.id, ctx.artifact, ctx.binding, identity)

    refute wrapped =~ identity

    assert {:ok, ^identity} =
             Envelope.unwrap(ctx.user.id, ctx.env.id, ctx.artifact, ctx.binding, wrapped)

    assert {:ok, another} =
             Envelope.wrap(ctx.user.id, ctx.env.id, ctx.artifact, ctx.binding, identity)

    refute wrapped == another

    for field <- ~w(fingerprint provider architecture base) do
      value = if field == "fingerprint", do: String.duplicate("b", 64), else: "other"
      changed = Map.put(ctx.binding, field, value)

      assert {:error, :invalid_envelope} =
               Envelope.unwrap(ctx.user.id, ctx.env.id, ctx.artifact, changed, wrapped)
    end

    assert {:error, :invalid_envelope} =
             Envelope.unwrap(ctx.user.id, ctx.env.id, Ecto.UUID.generate(), ctx.binding, wrapped)

    assert {:error, :invalid_envelope} =
             Envelope.unwrap(
               ctx.user.id,
               ctx.env.id,
               ctx.artifact,
               ctx.binding,
               binary_part(wrapped, 0, byte_size(wrapped) - 1)
             )
  end

  test "foreign and removed environments cannot wrap or unwrap", ctx do
    other = insert_verified_user()
    identity = "AGE-SECRET-KEY-1TEST-IDENTITY"

    assert {:error, :not_found} =
             Envelope.wrap(other.id, ctx.env.id, ctx.artifact, ctx.binding, identity)

    assert {:error, :not_found} =
             Envelope.unwrap(other.id, ctx.env.id, ctx.artifact, ctx.binding, <<>>)

    assert {:error, :not_found} =
             Envelope.wrap(ctx.user.id, Ecto.UUID.generate(), ctx.artifact, ctx.binding, identity)
  end

  test "rejects incomplete, foreign and unknown metadata instead of wrapping it", ctx do
    for binding <- [
          Map.delete(ctx.binding, "base"),
          Map.put(ctx.binding, "user", Ecto.UUID.generate()),
          Map.put(ctx.binding, "deletions", ["/etc/passwd"]),
          Map.put(ctx.binding, "version", 2)
        ] do
      assert {:error, :invalid_binding} =
               Envelope.wrap(
                 ctx.user.id,
                 ctx.env.id,
                 ctx.artifact,
                 binding,
                 "AGE-SECRET-KEY-1TEST"
               )
    end

    assert {:error, :invalid_identity} =
             Envelope.wrap(
               ctx.user.id,
               ctx.env.id,
               ctx.artifact,
               ctx.binding,
               "not-an-artifact-key"
             )
  end
end
