defmodule Managoat.Runtimes.Skills.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.Skills.Discovery

  defp md(name, extra \\ ""), do: "---\nname: #{name}\ndescription: d\n#{extra}---\nbody\n"

  defp names(files, opts \\ []) do
    files
    |> Discovery.discover(
      Keyword.get(opts, :manifests, %{}),
      Keyword.get(opts, :subpath),
      Keyword.take(opts, [:include_internal])
    )
    |> Enum.map(&{&1.name, &1.dir})
  end

  describe "discover/4" do
    test "a SKILL.md at the root is the one skill" do
      assert names(%{"" => md("root"), "skills/a" => md("a")}) == [{"root", ""}]
    end

    test "an invalid root SKILL.md does not stop the search" do
      assert names(%{"" => "no frontmatter", "skills/a" => md("a")}) == [{"a", "skills/a"}]
    end

    test "the root is searched one level deep, skills/ three, and a skill is not descended into" do
      files = %{
        "top" => md("top"),
        "examples/deep" => md("deep"),
        "skills/a" => md("a"),
        "skills/a/nested" => md("nested"),
        "skills/group/b" => md("b"),
        "skills/x/y/c" => md("c"),
        "skills/x/y/z/too-deep" => md("too-deep"),
        "skills/.curated/d" => md("d"),
        ".claude/skills/e" => md("e")
      }

      assert Enum.sort(names(files)) ==
               Enum.sort([
                 {"top", "top"},
                 {"a", "skills/a"},
                 {"b", "skills/group/b"},
                 {"c", "skills/x/y/c"},
                 {"d", "skills/.curated/d"},
                 {"e", ".claude/skills/e"}
               ])
    end

    test "skipped directories are tried but never descended" do
      files = %{
        "skills/node_modules" => md("tried"),
        "skills/node_modules/pkg" => md("hidden"),
        "skills/ok" => md("ok")
      }

      assert Enum.sort(names(files)) == [{"ok", "skills/ok"}, {"tried", "skills/node_modules"}]
    end

    test "falls back to every SKILL.md up to five levels when the priority walk finds none" do
      files = %{
        "examples/one/two" => md("deep"),
        "a/b/c/d/e" => md("five"),
        "a/b/c/d/e/f" => md("six"),
        "x/node_modules/y" => md("skipped")
      }

      assert Enum.sort(names(files)) == [{"deep", "examples/one/two"}, {"five", "a/b/c/d/e"}]
    end

    test "the first skill with a name wins" do
      assert names(%{"skills/a" => md("same"), "skills/b" => md("same")}) == [
               {"same", "skills/a"}
             ]
    end

    test "a SKILL.md without a string name and description does not count" do
      files = %{
        "skills/no-desc" => "---\nname: no-desc\n---\n",
        "skills/number" => "---\nname: 42\ndescription: d\n---\n",
        "skills/unclosed" => "---\nname: unclosed\ndescription: d\n",
        "skills/ok" => md("ok")
      }

      assert names(files) == [{"ok", "skills/ok"}]
    end

    test "an internal skill counts only when asked for by name" do
      files = %{"skills/a" => md("a"), "skills/i" => md("i", "metadata:\n  internal: true\n")}

      assert names(files) == [{"a", "skills/a"}]

      assert Enum.sort(names(files, include_internal: true)) == [
               {"a", "skills/a"},
               {"i", "skills/i"}
             ]
    end

    test "plugin manifests name more containers" do
      files = %{
        "skills/z" => md("z"),
        "plugins/docs/xlsx" => md("xlsx"),
        "plugins/docs/skills/pdf" => md("pdf")
      }

      assert names(files) == [{"z", "skills/z"}]

      marketplace =
        Jason.encode!(%{
          "plugins" => [
            %{"source" => "./plugins/docs", "skills" => ["./xlsx", "../../../escape"]},
            %{"source" => "https://elsewhere", "skills" => ["./ignored"]}
          ]
        })

      assert Enum.sort(
               names(files, manifests: %{".claude-plugin/marketplace.json" => marketplace})
             ) ==
               [
                 {"pdf", "plugins/docs/skills/pdf"},
                 {"xlsx", "plugins/docs/xlsx"},
                 {"z", "skills/z"}
               ]
    end

    test "a subpath is searched instead of the root" do
      files = %{"skills/a" => md("a"), "packs/one/skills/b" => md("b")}
      assert names(files, subpath: "packs/one") == [{"b", "packs/one/skills/b"}]
      assert names(files, subpath: "packs/one/skills/b") == [{"b", "packs/one/skills/b"}]
    end
  end

  test "select/2 matches a name ignoring case, or keeps everything" do
    skills = [%{name: "Internal-Comms", dir: "a"}, %{name: "pdf", dir: "b"}]
    assert Discovery.select(skills, nil) == skills
    assert Discovery.select(skills, "internal-comms") == [hd(skills)]
    assert Discovery.select(skills, "absent") == []
  end

  test "sanitize_name/1 is skills.sh's kebab case" do
    assert Discovery.sanitize_name("My Skill_v2") == "my-skill_v2"
    assert Discovery.sanitize_name("../../etc") == "etc"
    assert Discovery.sanitize_name("...") == "unnamed-skill"
  end

  describe "parse/2 reads the frontmatter forms skill repositories use" do
    test "quoted, folded and multi-line plain descriptions" do
      assert Discovery.parse(~s(---\nname: "q"\ndescription: 'it''s'\n---\n)) == "q"
      assert Discovery.parse("---\nname: f\ndescription: >-\n  folded\n  text\n---\n") == "f"
      assert Discovery.parse("---\nname: p\ndescription:\n  plain on\n  two lines\n---\n") == "p"
    end

    test "a byte-order mark, CRLF lines and other keys" do
      content =
        "﻿---\r\nname: crlf\r\nlicense: MIT\r\ndescription: d\r\nallowed-tools: Read Grep\r\n---\r\n"

      assert Discovery.parse(content) == "crlf"
    end

    test "a mapping is not a string" do
      assert Discovery.parse("---\nname: m\ndescription:\n  key: value\n---\n") == nil
    end

    test "control characters are removed from the name" do
      assert Discovery.parse("---\nname: a\e[31mb\ndescription: d\n---\n") == "ab"
    end
  end
end
