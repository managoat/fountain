"""An additive wire field changes generated Swift without a property registry."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("swiftgen", ROOT / "scripts/sdk-contract/generate-swift.py")
swiftgen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(swiftgen)


class SwiftGeneration(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads((ROOT / "sdk/contract/contract.json").read_text())

    def test_additive_fields_propagate_without_registration(self):
        changed = copy.deepcopy(self.contract)
        for owner in ["ConversationCreateRequest", "Conversation", "Turn"]:
            changed["schemas"][owner]["properties"]["future_switch"] = {
                "type": "boolean", "required": False, "nullable": True,
            }
        output = swiftgen.Generator(changed).render()
        self.assertEqual(output.count('case futureSwitch = "future_switch"'), 3)
        self.assertIn("public var futureSwitch: Bool?", output)
        self.assertIn("case .futureSwitch: _futureSwitch = .null", output)
        self.assertIn("try _futureSwitch.encode(into: &container, forKey: .futureSwitch)", output)
        self.assertNotIn("futureSwitch", swiftgen.Generator(self.contract).render())

    def test_sandbox_family_fields_propagate_without_registration(self):
        owners = ["Sandbox", "SandboxDetail", "SandboxConversation", "Runner", "ConversationTreeNode", "UsageTotal"]
        for owner in owners:
            self.contract["schemas"][owner]["properties"]["future_switch"] = {
                "type": "boolean", "required": False, "nullable": True,
            }
        output = swiftgen.Generator(self.contract).render()
        self.assertEqual(output.count('case futureSwitch = "future_switch"'), len(owners))
        self.assertIn("extension Sandbox {", output)
        self.assertIn("public struct RunnerRef:", output)
        self.assertIn("extension SandboxDetail {", output)

    def test_reused_inline_shapes_cannot_drift_silently(self):
        self.contract["schemas"]["SandboxDetail"]["properties"]["runner"]["properties"]["other"] = {"type": "string"}
        with self.assertRaisesRegex(ValueError, "Incompatible reused inline shape"):
            swiftgen.Generator(self.contract).render()

    def test_usage_alias_rejects_incompatible_fields(self):
        self.contract["schemas"]["UsageTotal"]["properties"]["input"]["type"] = "string"
        with self.assertRaisesRegex(ValueError, "Incompatible usage field: input"):
            swiftgen.Generator(self.contract).render()

    def test_resource_roots_and_nested_fields_propagate(self):
        # Each root is probed independently so a forgotten root cannot be
        # hidden by another model generating the same property.
        for owner in swiftgen.RESOURCE_ROOTS + ["VaultSecret"]:
            with self.subTest(owner=owner):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in swiftgen.SCHEMA_PATHS.get(owner, [owner]):
                    node = node[key]
                node["properties"]["future_switch"] = {
                    "type": "boolean", "required": False, "nullable": True,
                }
                output = swiftgen.Generator(contract).render()
                self.assertEqual(output.count('case futureSwitch = "future_switch"'), 1)
                self.assertIn("public var futureSwitch: Bool?", output)
                if owner in swiftgen.INPUT_ORDERS:
                    self.assertIn("case .futureSwitch: _futureSwitch = .null", output)
        # A required nested addition renders non-Optional, which is what the
        # compatibility guard stops by default, so these probes take the
        # exemption the guard offers rather than a pin.
        for path, owner in [
            (["Teammate", "properties", "presence"], "TeammatePresence"),
            (["CatalogResponse", "properties", "data", "properties", "apps"], "CatalogApps"),
            (["ApplySecretResult"], "ApplySecretResult"),
        ]:
            with self.subTest(path=path):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in path:
                    node = node[key]
                node["properties"]["future_label"] = {"type": "string", "required": True}
                with mock.patch.object(swiftgen, "REQUIRED_BY_CONTRACT", {(owner, "future_label")}):
                    output = swiftgen.Generator(contract).render()
                self.assertEqual(output.count('case futureLabel = "future_label"'), 1)
                self.assertIn("public var futureLabel: String\n", output)

    def test_shared_skill_shape_additions_and_conflicts(self):
        for owner in ["Agent", "AgentUpdate"]:
            self.contract["schemas"][owner]["properties"]["skills"]["items"]["properties"]["future_label"] = {
                "type": "string", "required": False,
            }
        output = swiftgen.Generator(self.contract).render()
        self.assertEqual(output.count('case futureLabel = "future_label"'), 1)
        self.contract["schemas"]["AgentUpdate"]["properties"]["skills"]["items"]["properties"]["future_label"]["type"] = "boolean"
        with self.assertRaisesRegex(ValueError, "Incompatible reused inline shape: AgentSkillsItem"):
            swiftgen.Generator(self.contract).render()

    def test_secret_alias_rejects_incompatible_shared_fields(self):
        self.contract["schemas"]["VaultSecret"]["properties"]["key"]["type"] = "integer"
        with self.assertRaisesRegex(ValueError, "Incompatible secret field: key"):
            swiftgen.Generator(self.contract).render()

    def test_optional_compat_pins_reach_a_live_property(self):
        # The table carries the whole backward-compatibility story. A pin whose
        # owner or key the contract renamed stops applying in silence, flipping
        # a public property back to non-Optional with every other gate green.
        generator = swiftgen.Generator(self.contract)
        generator.render()
        for owner, key in sorted(swiftgen.OPTIONAL_COMPAT):
            with self.subTest(owner=owner, key=key):
                self.assertIn(owner, generator.models)
                fields = {field[0]: field[3] for field in generator.models[owner]}
                self.assertIn(key, fields)

    def test_removed_properties_entries_name_a_real_removal(self):
        # The ratchet, the same shape as `test_optional_compat_pins_reach_a_live_property`
        # for the other tables: an entry that stops naming a property the
        # last release actually published, or one the current output still
        # generates, would be dead weight this guard would need to explain
        # rather than a caught regression, so it fails here instead of
        # staying silent.
        #
        # An entry has two lives, and the difference is which release is the
        # baseline. While the release it cites is still the last one, the
        # entry is load-bearing: `shipped` carries the key, the presence rule
        # would fail on it, and the entry is what clears that. Once the
        # release that removed the property has itself shipped, `shipped` no
        # longer carries the key, the rule -- which only ever looks at keys in
        # `shipped` -- can no longer consult the entry, and it is inert.
        #
        # Both lives have to pass here, because no single commit sees both.
        # Tagging is a consequence of merging, so the tree that becomes
        # vX.Y.Z is tested before the tag exists and again, as `main`, after
        # it does. Requiring the entry to be live made every release turn the
        # next CI run red (v0.18.0 did this to `AuthMe.onboardingState`), and
        # deleting it beforehand fails the pre-tag run instead. So an aged-out
        # entry is tolerated and checked for inertness; pruning it is
        # follow-up tidying, and the ceiling below is what stops the table
        # quietly filling with dead entries.
        shipped = swiftgen.released_properties()
        always_sent = swiftgen.released_requiredness()
        generator = swiftgen.Generator(copy.deepcopy(self.contract))
        generator.render()
        for name, key in sorted(swiftgen.REMOVED_PROPERTIES):
            with self.subTest(name=name, key=key):
                pruned = {k: v for k, v in swiftgen.REMOVED_PROPERTIES.items() if k != (name, key)}
                with mock.patch.object(swiftgen, "REMOVED_PROPERTIES", pruned):
                    reported = generator.compatibility_failures(shipped, always_sent)
                if (name, key) not in shipped:
                    self.assertEqual(
                        reported, [],
                        f"{name}.{key} is not published at {swiftgen.released_tag()}, so the "
                        "entry has aged out and should change nothing; it is still "
                        "changing the verdict",
                    )
                    continue
                self.assertTrue(
                    any(f"{name}.{key} shipped in" in failure for failure in reported),
                    f"{name}.{key} is not absent from the current output",
                )

    def test_the_removal_history_has_not_grown(self):
        # The ceiling that pays for tolerating an aged-out entry above. The
        # table may shrink freely -- pruning an entry the release moved past
        # is the expected tidying -- and growing it means editing this number
        # in the same diff, so a reviewer sees it move. Same shape as
        # `test_the_undescribed_property_table_has_not_grown`.
        ceiling = 5
        self.assertLessEqual(len(swiftgen.REMOVED_PROPERTIES), ceiling)
        for (name, key), reason in swiftgen.REMOVED_PROPERTIES.items():
            with self.subTest(name=name, key=key):
                self.assertTrue(reason.strip(), "every entry has to say why it exists")
                # An entry is a claim about a removal, so it cites the PR and
                # the fragment that made it (generate-swift.py's own rule).
                self.assertRegex(reason, r"#\d+", "an entry cites the PR that retired the property")

    def test_an_aged_out_removal_entry_is_inert_and_does_not_fail(self):
        # The release-advancement path, made explicit rather than left to
        # whichever entry happens to have aged out. An entry naming a
        # property no release published cannot be consulted by the presence
        # rule, so it neither clears nor causes a failure, and generation
        # still succeeds. This is what lets the table carry an entry across
        # the release that prunes it.
        shipped = swiftgen.released_properties()
        always_sent = swiftgen.released_requiredness()
        aged_out = ("AuthMe", "neverPublishedAnywhere")
        self.assertNotIn(aged_out, shipped)
        # Added to the live table, not substituted for it: dropping the
        # entries that are still load-bearing would fail generation for an
        # unrelated reason and prove nothing about this one.
        with mock.patch.object(
            swiftgen, "REMOVED_PROPERTIES",
            swiftgen.REMOVED_PROPERTIES | {aged_out: "aged out, #0000"},
        ):
            generator = swiftgen.Generator(copy.deepcopy(self.contract))
            generator.render()
            self.assertEqual(generator.compatibility_failures(shipped, always_sent), [])
        # And the verdict is the same without it, which is what "inert" means.
        baseline = swiftgen.Generator(copy.deepcopy(self.contract))
        baseline.render()
        self.assertEqual(baseline.compatibility_failures(shipped, always_sent), [])

    def test_a_vanished_property_fails_generation(self):
        # The reproduction #2296 describes: a property stops being generated
        # and nothing else catches it, because the two existing rules compare
        # optionality rather than presence. `EXTRA_PROPERTIES` emptied is the
        # issue's own repro, covered in `test_undescribed_properties_reach_the_output`;
        # this is the ordinary path, a property the contract simply drops.
        contract = copy.deepcopy(self.contract)
        del contract["schemas"]["Agent"]["properties"]["description"]
        with self.assertRaisesRegex(
            ValueError, r"Agent\.description shipped in \S+ and is no longer generated"
        ):
            swiftgen.Generator(contract).render()

    def test_a_recorded_removal_passes(self):
        # The remedy: citing the removal in REMOVED_PROPERTIES clears the
        # failure the previous test raises, the same shape as pinning a
        # property in OPTIONAL_COMPAT or REQUIRED_BY_CONTRACT clears theirs.
        contract = copy.deepcopy(self.contract)
        del contract["schemas"]["Agent"]["properties"]["description"]
        with mock.patch.object(
            swiftgen, "REMOVED_PROPERTIES",
            swiftgen.REMOVED_PROPERTIES | {("Agent", "description"): "test removal"},
        ):
            output = swiftgen.Generator(contract).render()
        body = output.split("public struct Agent:", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("description", body)

    def test_a_newly_required_property_needs_a_pin_or_an_exemption(self):
        # The direction that breaks consumers, and the one the pin test above
        # cannot see. `Teammate` is the type that proved it (#2284): four public
        # TeamResource methods decode it and no fixture ever did, so a required
        # addition reached a release with every gate green.
        for owner, shipped in [("Teammate", "Teammate"), ("Catalog", "Catalog")]:
            with self.subTest(owner=owner):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in swiftgen.SCHEMA_PATHS.get(owner, [owner]):
                    node = node[key]
                node["properties"]["probe_required"] = {"type": "string", "required": True}
                with self.assertRaisesRegex(ValueError, f"{shipped}.probeRequired is required here"):
                    swiftgen.Generator(contract).render()
                # Either recorded decision satisfies the guard; only silence fails.
                with mock.patch.object(
                    swiftgen, "OPTIONAL_COMPAT", swiftgen.OPTIONAL_COMPAT | {(owner, "probe_required")}
                ):
                    self.assertIn("public var probeRequired: String?", swiftgen.Generator(contract).render())
                with mock.patch.object(swiftgen, "REQUIRED_BY_CONTRACT", {(owner, "probe_required")}):
                    self.assertIn("public var probeRequired: String\n", swiftgen.Generator(contract).render())

    def test_a_property_this_sdk_published_optional_stays_optional(self):
        # The second rule, and the only one covering a property the released
        # server always sent: decoding is safe, but flipping the published `x?`
        # to `x` breaks a consumer's code. 38 of the pins are held by this rule
        # alone, so without it they could be deleted for a silent API change.
        always_sent = swiftgen.released_requiredness()
        shipped = swiftgen.released_properties()
        held = [(owner, key) for owner, key in sorted(swiftgen.OPTIONAL_COMPAT)
                if always_sent.get((owner, key))
                and shipped.get((swiftgen.TYPE_NAMES.get(owner, owner), swiftgen.camel(key)))]
        self.assertGreater(len(held), 20)
        # The second is published escaped, because `default` is a Swift keyword.
        # The parser missed it while the generated side spelled it `` `default` ``,
        # so this live pin could be deleted with every gate green.
        for owner, key, message in [
            ("AdminSandbox", "status", "AdminSandbox.status shipped Optional"),
            ("CatalogSandboxProviders", "default", r"Catalog.SandboxProviders.`default` shipped Optional"),
        ]:
            with self.subTest(owner=owner, key=key):
                self.assertIn((owner, key), held)
                pins = {pin for pin in swiftgen.OPTIONAL_COMPAT if pin != (owner, key)}
                with mock.patch.object(swiftgen, "OPTIONAL_COMPAT", pins):
                    with self.assertRaisesRegex(ValueError, message):
                        swiftgen.Generator(copy.deepcopy(self.contract)).render()

    def test_the_exemption_cannot_authorize_a_source_break(self):
        # REQUIRED_BY_CONTRACT claims every deployed server sends the key. That
        # can establish decoding is safe; it cannot make an already-public `T?`
        # becoming `T` source-compatible, so it must not reach that rule — or
        # the documented escape hatch re-authorizes the regression the escaped
        # `default` pin exists to prevent.
        owner, key = ("CatalogSandboxProviders", "default")
        pins = {pin for pin in swiftgen.OPTIONAL_COMPAT if pin != (owner, key)}
        with mock.patch.object(swiftgen, "OPTIONAL_COMPAT", pins):
            with mock.patch.object(swiftgen, "REQUIRED_BY_CONTRACT", {(owner, key)}):
                with self.assertRaisesRegex(ValueError, r"Catalog.SandboxProviders.`default` shipped Optional"):
                    swiftgen.Generator(copy.deepcopy(self.contract)).render()
        # It still answers the rule it is for: a property no release published.
        contract = copy.deepcopy(self.contract)
        contract["schemas"]["Teammate"]["properties"]["probe_required"] = {
            "type": "string", "required": True,
        }
        with mock.patch.object(swiftgen, "REQUIRED_BY_CONTRACT", {("Teammate", "probe_required")}):
            self.assertIn("public var probeRequired: String\n", swiftgen.Generator(contract).render())

    def test_a_property_can_owe_both_rules(self):
        # The rules are answered independently, so a property that trips both
        # reports both: the remedies differ and only one has an escape hatch.
        contract = copy.deepcopy(self.contract)
        contract["schemas"]["Agent"]["properties"]["description"]["required"] = True
        generator = swiftgen.Generator(copy.deepcopy(contract))
        try:
            generator.render()
        except ValueError:
            pass
        reported = generator.compatibility_failures(
            swiftgen.released_properties(), swiftgen.released_requiredness())
        self.assertIn("Agent.description is required here and the last release could omit it", reported)
        self.assertIn("Agent.description shipped Optional and the contract now requires it", reported)

    def test_the_released_swift_parser_reads_every_published_property(self):
        # The source rule is only as good as this parser: a property it cannot
        # see has no baseline, so its pin can be deleted in silence. Escaped
        # names were the hole. Count the release's own declarations rather than
        # trusting a list, so the next unusual spelling fails here.
        declarations = 0
        for path in swiftgen.released("ls-tree", "-r", "--name-only", "<tag>", "--", swiftgen.RELEASED_MODELS).split():
            text = swiftgen.released("show", f"<tag>:{path}")
            declarations += len([line for line in text.splitlines()
                                 if re.match(r"\s*public var ", line)])
        self.assertEqual(len(swiftgen.released_properties()), declarations)
        self.assertEqual(swiftgen.released_properties()["Catalog.SandboxProviders", "default"], True)

    def test_the_released_tag_is_the_baseline_for_both_questions(self):
        # No baseline file to keep in step; both come from the last release.
        #
        # Nothing here may name a fact about one particular release. This test
        # used to assert that `CatalogMcpServersItem` was absent from the
        # released Swift and that `Teammate.name` was required -- both true of
        # v0.17.1, and the first of them false the moment v0.18.0 shipped the
        # generated resource models, which turned the release's own tag into a
        # red CI run on `main`. A baseline fixture that quotes the current
        # release expires on the next one, so assert the mechanism instead and
        # let the release supply its own examples.
        always_sent = swiftgen.released_requiredness()
        shipped = swiftgen.released_properties()
        self.assertTrue(always_sent, "the released contract is the requiredness baseline")
        self.assertTrue(shipped, "the released Swift is the optionality baseline")
        # Both discriminate rather than answering one way for everything: a
        # baseline stuck at all-True or all-False would satisfy a subset of
        # the rules while measuring nothing.
        for name, baseline in [("always_sent", always_sent), ("shipped", shipped)]:
            with self.subTest(baseline=name):
                self.assertEqual({type(value) for value in baseline.values()}, {bool})
                self.assertIn(True, baseline.values())
                self.assertIn(False, baseline.values())
        # The released Swift is read with its nested types, whichever release
        # it is: handwritten nested types were declared inside their parent
        # and generated ones in an extension, and both have to read as one
        # dotted key. `test_the_released_swift_parser_reads_every_published_property`
        # pins the exact count against the release's own declarations.
        self.assertTrue([owner for owner, _ in shipped if "." in owner],
                        "nested types reach the optionality baseline")
        generator = swiftgen.Generator(copy.deepcopy(self.contract))
        generator.render()
        self.assertEqual(generator.compatibility_failures(shipped, always_sent), [])
        # Neither baseline knowing the type means no older server emits it.
        self.assertEqual(generator.compatibility_failures({}, {}), [])

    def test_both_baselines_read_the_release_tag(self):
        # What the test above is named for, asserted directly instead of
        # through literals that quote whichever release is current.
        #
        # Not by pointing the readers at an older tag: an older contract can
        # carry a shape the *current* generator refuses -- v0.17.0's does,
        # since #2288 -- so reading a real earlier release raises for a
        # reason that has nothing to do with baselines. Capture the git calls
        # instead and assert the tag is what both readers ask for. This also
        # guards the caching: both memoize, and a cache that outlived the tag
        # would answer for the wrong release.
        sentinel = "v0.0.0-probe"
        contract = json.dumps(self.contract)
        model = "public struct Probe: Codable {\n    public var only: String?\n}\n"
        calls = []

        def fake_git(*args):
            calls.append(args)
            if args[0] == "ls-tree":
                return f"{swiftgen.RELEASED_MODELS}/Probe.swift\n"
            if args[0] == "show" and args[1].endswith(":sdk/contract/contract.json"):
                return contract
            if args[0] == "show":
                return model
            raise AssertionError(f"unexpected git call: {args}")

        def clear():
            for reader in (swiftgen.released_tag, swiftgen.released_requiredness,
                           swiftgen.released_properties):
                reader.cache_clear()

        try:
            clear()
            with mock.patch.object(swiftgen, "released_tag", lambda: sentinel), \
                 mock.patch.object(swiftgen, "_git", fake_git):
                swiftgen.released_requiredness.cache_clear()
                swiftgen.released_properties.cache_clear()
                self.assertTrue(swiftgen.released_requiredness())
                self.assertEqual(swiftgen.released_properties(), {("Probe", "only"): True})
            # Every tree read carried the tag, so neither baseline can drift
            # to the working tree or to a branch.
            self.assertTrue(calls, "the baselines read the tree through git")
            for args in calls:
                with self.subTest(args=args):
                    self.assertTrue(
                        any(sentinel in str(argument) for argument in args),
                        "a baseline read that does not name the release tag",
                    )
        finally:
            # Leave the module's caches holding the real release, or every
            # test after this one measures the wrong tree.
            clear()
            swiftgen.released_requiredness()
            swiftgen.released_properties()

    def test_a_shape_the_sdk_never_exposed_is_still_an_older_server_shape(self):
        # Absence from the released SDK is not absence from the released
        # server. `CatalogMcpServersItem` is a contract shape from before
        # v0.17.1 that the v0.17.1 Swift models did not expose, so treating it
        # as wholly new lets a required addition break an older server's whole
        # `Catalog` response — one bad item kills the enclosing response.
        for path in [
            ["CatalogResponse", "properties", "data", "properties", "mcp_servers", "items"],
            ["CatalogResponse", "properties", "data", "properties", "first_request"],
        ]:
            with self.subTest(path=path[-2]):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in path:
                    node = node[key]
                node["properties"]["probe_required"] = {"type": "string", "required": True}
                with self.assertRaisesRegex(ValueError, "probeRequired is required here"):
                    swiftgen.Generator(contract).render()

    def test_a_property_the_release_always_sent_may_be_required(self):
        # The other side of the same rule, and why REQUIRED_BY_CONTRACT is
        # still empty: `first_request` arrived whole in #1443, so the released
        # contract requires its four members and no pin is needed for them.
        always_sent = swiftgen.released_requiredness()
        for key in ["curl", "placeholders", "prompt", "typescript"]:
            self.assertTrue(always_sent["CatalogFirstRequest", key])
        output = swiftgen.Generator(copy.deepcopy(self.contract)).render()
        self.assertIn("public var prompt: String\n", output)
        self.assertEqual(swiftgen.REQUIRED_BY_CONTRACT, set())

    def test_a_regenerated_candidate_cannot_authorize_itself(self):
        # The realistic bypass: a change makes a property required and commits
        # the regenerated output, so a baseline read from the working tree sees
        # the candidate's own field as already shipped and reports nothing.
        contract = copy.deepcopy(self.contract)
        contract["schemas"]["Teammate"]["properties"]["probe_required"] = {
            "type": "string", "required": True,
        }
        with mock.patch.object(swiftgen, "REQUIRED_BY_CONTRACT", {("Teammate", "probe_required")}):
            candidate = swiftgen.Generator(copy.deepcopy(contract)).render()
            generator = swiftgen.Generator(copy.deepcopy(contract))
            generator.render()
        self.assertIn("public var probeRequired: String\n", candidate)
        candidate_baseline = swiftgen.public_properties(candidate, {})
        self.assertEqual(generator.compatibility_failures(candidate_baseline, {}), [])
        self.assertTrue(generator.compatibility_failures(
            swiftgen.released_properties(), swiftgen.released_requiredness()))
        with self.assertRaisesRegex(ValueError, "Teammate.probeRequired"):
            swiftgen.Generator(copy.deepcopy(contract)).render()

    def test_input_only_models_answer_to_the_request_contract(self):
        # This guard is about decoding a response. An input root is encoded and
        # never decoded, and pinning a request property would let a field the
        # server requires be omitted and the request rejected — so a required
        # addition there is not this rule's business.
        for owner in sorted(swiftgen.Generator(self.contract).input_roots):
            with self.subTest(owner=owner):
                contract = copy.deepcopy(self.contract)
                node = contract["schemas"]
                for key in swiftgen.SCHEMA_PATHS.get(owner, [owner]):
                    node = node[key]
                node["properties"]["probe_required"] = {"type": "string", "required": True}
                output = swiftgen.Generator(contract).render()
                self.assertIn("public var probeRequired: String\n", output)
                # Not omissible: no ConversationInputField storage behind it, so
                # the encoder cannot leave the key out of the request.
                self.assertNotIn("_probeRequired", output)

    def test_an_inline_name_colliding_with_a_schema_fails(self):
        # build() resolves self.schemas before self.nested, so before this
        # check the inline shape was discarded and the field took the unrelated
        # schema's type with nothing to see in the output. The synthesized-name
        # and schema-name sets do not intersect on today's contract.
        self.contract["schemas"]["Connection"]["properties"]["provider"] = {
            "type": "object", "required": True,
            "properties": {"slug": {"type": "string", "required": True}},
        }
        with self.assertRaisesRegex(ValueError, "collides with schema ConnectionProvider"):
            swiftgen.Generator(self.contract).render()

    def test_a_node_with_both_properties_and_additional_properties_fails(self):
        # `[String: JSONValue]` throws the declared properties away, which is
        # the opposite of what the module promises for unknown shapes. The
        # contract's only both-shaped nodes are the two `networking_config`,
        # which TYPE_OVERRIDES already answers.
        self.contract["schemas"]["Agent"]["properties"]["probe_open"] = {
            "type": "object", "required": False, "additionalProperties": True,
            "properties": {"slug": {"type": "string", "required": True}},
        }
        with self.assertRaisesRegex(ValueError, "Both additionalProperties and properties at Agent.probe_open"):
            swiftgen.Generator(self.contract).render()
        with mock.patch.dict(swiftgen.TYPE_OVERRIDES, {("Agent", "probe_open"): "JSONValue"}):
            self.assertIn("public var probeOpen: JSONValue?", swiftgen.Generator(self.contract).render())

    def test_an_enum_array_keeps_the_item_type_its_scalar_sibling_has(self):
        output = swiftgen.Generator(copy.deepcopy(self.contract)).render()
        # The same wire field, typed the same way in both places.
        self.assertIn("public var sandboxAPIAccess: [SandboxAPIAccess]?", output)
        self.assertIn("public var sandboxAPIAccess: SandboxAPIAccess?", output)
        # Every wrapper `type()` looks through, because reading the item's own
        # keys instead would pass the shape straight to the generator it is
        # meant to stop: an `enum` inside `allOf` generated `[String]?`.
        enum = {"type": "string", "enum": ["one", "two"]}
        nothing = {"enum": ["None"], "nullable": True}
        for label, items in [
            ("direct", enum),
            ("allOf", {"allOf": [enum]}),
            ("anyOf", {"anyOf": [enum]}),
            ("oneOf", {"oneOf": [enum]}),
            ("nullable anyOf", {"anyOf": [enum, nothing]}),
            ("allOf inside anyOf", {"anyOf": [{"allOf": [enum]}, nothing]}),
        ]:
            with self.subTest(items=label):
                contract = copy.deepcopy(self.contract)
                contract["schemas"]["Agent"]["properties"]["probe_kinds"] = {
                    "type": "array", "required": False, "items": items,
                }
                with self.assertRaisesRegex(ValueError, "Untyped enum array at Agent.probe_kinds"):
                    swiftgen.Generator(contract).render()
                with mock.patch.dict(swiftgen.ENUM_TYPES, {("Agent", "probe_kinds_item"): "Runtime"}):
                    self.assertIn("public var probeKinds: [Runtime]?", swiftgen.Generator(contract).render())

    def test_the_undescribed_property_table_has_not_grown(self):
        # The ratchet, the same shape as SchemaGuardAllowlist's ceiling in
        # apps/fountain: the table may shrink freely, and growing it means
        # editing this number in the same diff, so a reviewer sees it move.
        # Every entry is a claim that the server sends a field the contract
        # does not document. It held the SSE frame's two fields until #2297
        # described the frame as StreamLogEvent, which retired both — the
        # ceiling is 0 rather than deleted so a new entry still has to move it.
        ceiling = 0
        self.assertLessEqual(len(swiftgen.EXTRA_PROPERTIES), ceiling)
        for (owner, key), (node, reason) in swiftgen.EXTRA_PROPERTIES.items():
            with self.subTest(owner=owner, key=key):
                self.assertTrue(reason.strip(), "every entry has to say why it exists")
                self.assertIn("type", node)
                # If the contract describes it, the entry is duplication now:
                # the ordinary path would generate the property from the
                # schema, and two sources for one field is the whole problem.
                schema = self.contract["schemas"]
                for segment in swiftgen.SCHEMA_PATHS.get(owner, [owner]):
                    schema = schema[segment]
                self.assertNotIn(
                    key, schema.get("properties", {}),
                    f"the contract now describes {owner}.{key}; delete the entry")

    def test_stream_only_log_event_properties_reach_the_output(self):
        # Scoped to the one struct: `conversation_id` is a real contract
        # property on several other models, so a whole-file search would pass
        # whether or not this worked.
        def log_event(output):
            body = output.split("public struct LogEvent:", 1)[1]
            return body.split("\n}", 1)[0]

        generated = log_event(swiftgen.Generator(copy.deepcopy(self.contract)).render())
        self.assertIn('case conversationID = "conversation_id"', generated)
        self.assertIn('case agentID = "agent_id"', generated)
        # Optional because no shape always carries them: the REST row carries
        # neither, and only the team stream carries agent_id.
        self.assertIn("public var conversationID: String?", generated)
        self.assertIn("public var agentID: String?", generated)

        # #2297: these come from StreamLogEvent now, not EXTRA_PROPERTIES —
        # confirm it is genuinely load-bearing rather than vestigial. `build()`
        # alone, not `render()`, so this exercises field sourcing without also
        # tripping the disappearance guard the next test is about.
        without_agent_id = copy.deepcopy(self.contract)
        del without_agent_id["schemas"]["StreamLogEvent"]["properties"]["agent_id"]
        generator = swiftgen.Generator(without_agent_id)
        generator.build()
        keys = {key for key, _, _, _ in generator.models["LogEvent"]}
        self.assertNotIn("agent_id", keys)
        self.assertIn("conversation_id", keys)

    def test_a_stream_field_disappearing_from_the_contract_is_caught(self):
        # Emptying EXTRA_PROPERTIES used to drop both properties in silence
        # (#2296). Now that they are ordinary contract-sourced fields,
        # `compatibility_failures` — the disappearance guard every generated
        # model already goes through — catches this with no table to empty
        # at all: the last release published both, and nothing records
        # removing either as deliberate.
        contract = copy.deepcopy(self.contract)
        del contract["schemas"]["StreamLogEvent"]["properties"]["conversation_id"]
        with self.assertRaisesRegex(ValueError, "LogEvent.conversationID shipped"):
            swiftgen.Generator(contract).render()

    def test_the_published_duration_spelling_is_preserved(self):
        # `duration_ms` published as `durationMS`, so `ms` joins the acronym
        # map. Nothing generated ended in `Ms` before this, so no property is
        # renamed by it — a rename is a source break neither guard can see,
        # because both are keyed by the property name.
        self.assertEqual(swiftgen.camel("duration_ms"), "durationMS")
        output = swiftgen.Generator(copy.deepcopy(self.contract)).render()
        self.assertIn("public var durationMS: Int?", output)
        self.assertNotIn("durationMs", output)

    def test_generation_is_deterministic(self):
        self.assertEqual(swiftgen.Generator(self.contract).render(), swiftgen.Generator(self.contract).render())

    def test_unknown_shapes_fail_loudly(self):
        self.contract["schemas"]["Conversation"]["properties"]["future_union"] = {
            "oneOf": [{"type": "string"}, {"type": "integer"}], "required": False,
        }
        with self.assertRaisesRegex(ValueError, "Unsupported union at Conversation.future_union"):
            swiftgen.Generator(self.contract).render()


if __name__ == "__main__":
    unittest.main()
