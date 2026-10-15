defmodule Managoat.ACP.ElicitationTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.Elicitation

  @schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"},
      "size" => %{"type" => "string", "enum" => ["s", "m"]},
      "count" => %{"type" => "integer"},
      "ratio" => %{"type" => "number"},
      "ok" => %{"type" => "boolean"},
      "tags" => %{"type" => "array", "items" => %{"enum" => ["a", "b"]}},
      "free" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["name"]
  }

  test "form_declared?/1 reads atom and string keys, and wants an object" do
    assert Elicitation.form_declared?(%{elicitation: %{form: %{}}})
    assert Elicitation.form_declared?(%{"elicitation" => %{"form" => %{}}})
    refute Elicitation.form_declared?(%{elicitation: %{form: true}})
    refute Elicitation.form_declared?(%{elicitation: %{url: %{}}})
    refute Elicitation.form_declared?(Managoat.ACP.Protocol.default_client_capabilities())
  end

  test "form?/1: form is the default mode" do
    assert Elicitation.form?(%{})
    assert Elicitation.form?(%{"mode" => "form"})
    refute Elicitation.form?(%{"mode" => "url"})
  end

  test "an accept is checked field by field" do
    ok = %{
      "name" => "x",
      "size" => "m",
      "count" => 2,
      "ratio" => 0.5,
      "ok" => true,
      "tags" => ["a"],
      "free" => ["anything"]
    }

    assert {:ok, %{action: "accept", content: ^ok}} = Elicitation.result(@schema, "accept", ok)

    for {bad, field} <- [
          {%{"name" => 1}, "name"},
          {%{"name" => "x", "size" => "xl"}, "size"},
          {%{"name" => "x", "count" => 1.5}, "count"},
          {%{"name" => "x", "ok" => "yes"}, "ok"},
          {%{"name" => "x", "tags" => ["c"]}, "tags"},
          {%{"name" => "x", "free" => [1]}, "free"},
          {%{"name" => "x", "nope" => "x"}, "nope"},
          {%{}, "name"}
        ] do
      assert {:error, {:invalid_content, why}} = Elicitation.result(@schema, "accept", bad)
      assert why =~ field, inspect({bad, why})
    end
  end

  test "decline and cancel carry no content" do
    assert {:ok, %{action: "decline"}} = Elicitation.result(@schema, "decline", nil)
    assert {:ok, %{action: "cancel"}} = Elicitation.result(@schema, "cancel", %{})

    assert {:error, {:invalid_content, _}} =
             Elicitation.result(@schema, "decline", %{"name" => "x"})

    assert {:error, :unknown_action} = Elicitation.result(@schema, "later", nil)
  end
end
