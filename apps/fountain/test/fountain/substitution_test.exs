defmodule Fountain.SubstitutionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fountain.Substitution

  doctest Substitution

  describe "apply/2 — string substitution" do
    test "substitutes a single variable" do
      assert {:ok, "hello world"} = Substitution.apply("hello ${NAME}", %{"NAME" => "world"})
    end

    test "substitutes multiple variables" do
      vars = %{"FIRST" => "John", "LAST" => "Doe"}
      assert {:ok, "John Doe"} = Substitution.apply("${FIRST} ${LAST}", vars)
    end

    test "substitutes the same variable appearing multiple times" do
      vars = %{"X" => "42"}
      assert {:ok, "42 and 42"} = Substitution.apply("${X} and ${X}", vars)
    end

    test "leaves non-variable text untouched" do
      assert {:ok, "plain text"} = Substitution.apply("plain text", %{})
    end

    test "handles empty string" do
      assert {:ok, ""} = Substitution.apply("", %{})
    end
  end

  describe "apply/2 — escape sequences" do
    test "$$ becomes a literal dollar sign" do
      assert {:ok, "$"} = Substitution.apply("$$", %{})
    end

    test "$$ escape works adjacent to substitution" do
      assert {:ok, "$100"} = Substitution.apply("$$${AMOUNT}", %{"AMOUNT" => "100"})
    end

    test "multiple $$ sequences each become one $" do
      assert {:ok, "$$"} = Substitution.apply("$$$$", %{})
    end
  end

  describe "apply/2 — missing variables" do
    test "returns error tuple listing missing variable" do
      assert {:error, {:missing_vars, ["MISSING"]}} =
               Substitution.apply("${MISSING}", %{})
    end

    test "collects all missing variables, not just the first" do
      assert {:error, {:missing_vars, missing}} =
               Substitution.apply("${A} and ${B}", %{})

      assert Enum.sort(missing) == ["A", "B"]
    end

    test "missing vars list is sorted" do
      assert {:error, {:missing_vars, ["A", "B", "C"]}} =
               Substitution.apply("${C} ${A} ${B}", %{})
    end

    test "partial vars: only reports the truly missing ones" do
      assert {:error, {:missing_vars, ["B"]}} =
               Substitution.apply("${A} ${B}", %{"A" => "present"})
    end
  end

  describe "apply/2 — recursive walk" do
    test "substitutes inside a list" do
      assert {:ok, ["hello world"]} =
               Substitution.apply(["hello ${NAME}"], %{"NAME" => "world"})
    end

    test "substitutes inside a nested map" do
      input = %{"outer" => %{"inner" => "${VAL}"}}

      assert {:ok, %{"outer" => %{"inner" => "42"}}} =
               Substitution.apply(input, %{"VAL" => "42"})
    end

    test "substitutes inside a map with mixed types" do
      input = %{"key" => "${X}", "num" => 42}

      assert {:ok, %{"key" => "hello", "num" => 42}} =
               Substitution.apply(input, %{"X" => "hello"})
    end

    test "collects missing vars across nested structure" do
      input = %{"a" => "${FOO}", "b" => ["${BAR}"]}
      assert {:error, {:missing_vars, missing}} = Substitution.apply(input, %{})
      assert Enum.sort(missing) == ["BAR", "FOO"]
    end
  end

  describe "apply/2 — property tests" do
    property "substituting a variable always returns the provided value" do
      check all(
              key <- string(:alphanumeric, min_length: 1),
              key = String.upcase(key),
              String.match?(key, ~r/^[A-Z_][A-Z0-9_]*$/),
              value <- string(:printable)
            ) do
        template = "${#{key}}"
        assert {:ok, ^value} = Substitution.apply(template, %{key => value})
      end
    end

    property "plain strings with no $ pass through unchanged" do
      check all(s <- string(:alphanumeric)) do
        assert {:ok, ^s} = Substitution.apply(s, %{})
      end
    end

    property "applying with all vars provided always returns :ok" do
      check all(
              pairs <-
                list_of(
                  {
                    string(:alphanumeric, min_length: 1)
                    |> map(&String.upcase/1)
                    |> filter(&String.match?(&1, ~r/^[A-Z][A-Z0-9_]*$/)),
                    string(:printable)
                  },
                  min_length: 1
                )
            ) do
        vars = Map.new(pairs)
        template = vars |> Map.keys() |> Enum.map_join(" ", &"${#{&1}}")
        assert {:ok, _} = Substitution.apply(template, vars)
      end
    end
  end
end
