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
        # The released contract says what that server always sent.
        always_sent = swiftgen.released_requiredness()
        self.assertTrue(always_sent["Teammate", "name"])
        self.assertFalse(always_sent["Agent", "description"])
        # A shape the released SDK never exposed is still one that server
        # emitted, so it is in this baseline even though it is not in the next.
        self.assertTrue(always_sent["CatalogMcpServersItem", "slug"])
        # The released Swift says what this SDK already published as Optional,
        # including the models that shipped handwritten. Handwritten nested
        # types were declared inside their parent and generated ones in an
        # extension; both have to read as the same key.
        shipped = swiftgen.released_properties()
        self.assertEqual(shipped["Teammate", "name"], False)
        self.assertEqual(shipped["Teammate", "usageTotal"], True)
        self.assertEqual(shipped["Teammate.Presence", "label"], True)
        self.assertEqual(shipped["Sandbox.RunnerRef", "online"], True)
        self.assertNotIn("CatalogMcpServersItem", {owner for owner, _ in shipped})
        generator = swiftgen.Generator(copy.deepcopy(self.contract))
        generator.render()
        self.assertEqual(generator.compatibility_failures(shipped, always_sent), [])
        # Neither baseline knowing the type means no older server emits it.
        self.assertEqual(generator.compatibility_failures({}, {}), [])

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
        # does not document, which is true of the SSE frame and should stay
        # rare.
        ceiling = 2
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

    def test_undescribed_properties_reach_the_output(self):
        # Scoped to the one struct: `conversation_id` is a real contract
        # property on several other models, so a whole-file search would pass
        # whether or not the table did anything.
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
        with mock.patch.object(swiftgen, "EXTRA_PROPERTIES", {}):
            bare = log_event(swiftgen.Generator(copy.deepcopy(self.contract)).render())
        self.assertNotIn("conversationID", bare)
        self.assertNotIn("agentID", bare)

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
