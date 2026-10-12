defmodule Fountain.FeatureFlagsTest do
  # Mutates global app env (the overrides), so not async.
  use ExUnit.Case, async: false

  alias Fountain.FeatureFlags

  @user_id "11111111-1111-1111-1111-111111111111"

  # A neutral flag key, not one of `@flags`: `enabled?/2` takes the string
  # directly, so this suite does not pin itself to whichever real flag happens
  # to exist (#2252).
  @flag "test_flag"

  setup do
    previous = Application.get_env(:fountain, :feature_flag_overrides)
    Application.put_env(:fountain, :feature_flag_overrides, %{})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :feature_flag_overrides, previous),
        else: Application.delete_env(:fountain, :feature_flag_overrides)
    end)

    :ok
  end

  test "a flag nobody turned on reads off" do
    refute FeatureFlags.enabled?(@flag, @user_id)
  end

  test "an override turns a flag on for everyone" do
    Application.put_env(:fountain, :feature_flag_overrides, %{@flag => true})
    assert FeatureFlags.enabled?(@flag, @user_id)
    assert FeatureFlags.enabled?(@flag, %{id: @user_id})
    assert FeatureFlags.enabled?(@flag, nil)
  end

  test "an unknown flag atom is a KeyError, not a silent off" do
    assert_raise KeyError, fn -> FeatureFlags.enabled?(:no_such_flag, @user_id) end
  end

  # A flag over a shipped feature reads on by default, or a deployment loses
  # the feature on the upgrade that added the flag (#1693).
  test "a flag that gates a shipped feature reads on" do
    assert FeatureFlags.enabled?(:connections, @user_id)
    assert FeatureFlags.enabled?(:connections, nil)
  end

  # Linking a ChatGPT subscription is behind gates ADR 0060 has not passed, so
  # a deployment does not get it unless FEATURE_FLAGS_ON names it.
  test "the chatgpt_subscriptions flag is off until listed" do
    refute FeatureFlags.enabled?(:chatgpt_subscriptions, @user_id)

    Application.put_env(:fountain, :feature_flag_overrides, %{"chatgpt_subscriptions" => true})
    assert FeatureFlags.enabled?(:chatgpt_subscriptions, @user_id)
  end

  test "an override decides in both directions" do
    Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => false})
    refute FeatureFlags.enabled?(:connections, @user_id)
  end
end
