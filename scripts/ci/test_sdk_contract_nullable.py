"""`nullable: true` on a composed schema has to mean it (#1899).

The bug this pins: `permission_policy` was extracted to a named component and
referenced as `{"nullable": true, "allOf": [{"$ref": ...}]}`. That reads as
nullable and is not. In OpenAPI 3.0 `nullable` relaxes the type of the node it
sits on and nothing else; the wrapper carries no `type`, so its flag is
vacuous, and the referenced schema — which is where `type: object` lives —
never saw it. All five fields stopped accepting a `null` the server still
sends, and **every gate in the repository stayed green**: `OpenApiSpex`
answers null at `Cast.cast/1` before the composition is ever consulted, so
6008 Elixir tests, four contract verifiers and the TypeScript typecheck could
not see it. A document-level bug needs a document-level check.

`SHAPES` below is that check's ground truth. Every row was run through
`openapi-schema-validator` 0.9.0's `OAS30Validator` while the guard was
written, and `accepts_null` agreed on all of them. Re-run that cross-check if
you change the rule:

    pip install openapi-schema-validator==0.9.0
    # then validate each shape's `null` against OAS30Validator and compare

The third-party validator is deliberately not a test dependency — `scripts/ci`
runs on a bare `python3` in `workflow-checks` — so the rule lives here and its
agreement with a real validator is recorded rather than re-derived.
"""

from pathlib import Path
import json
import sys
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts" / "sdk-contract"))
import build  # noqa: E402

REF = {"$ref": "#/components/schemas/Thing"}


def spec(component: dict, **properties) -> dict:
    """A document with one component, `Thing`, and a `Holder` schema using it."""
    return {
        "components": {
            "schemas": {
                "Thing": component,
                "Holder": {"type": "object", "properties": properties},
            }
        }
    }


PLAIN_THING = {"type": "object", "properties": {"a": {"type": "string"}}}
NULLABLE_THING = dict(PLAIN_THING, nullable=True)

NULL_BRANCH = {"nullable": True, "enum": [None]}

# (label, the component `Thing` is, the node under test, does OAS 3.0 take null)
SHAPES = [
    ("nullable wrapper over allOf[$ref]", PLAIN_THING, {"nullable": True, "allOf": [REF]}, False),
    ("nullable wrapper over oneOf[$ref]", PLAIN_THING, {"nullable": True, "oneOf": [REF]}, False),
    ("type:object too, still allOf[$ref]", PLAIN_THING,
     {"type": "object", "nullable": True, "allOf": [REF]}, False),
    ("bare $ref to a plain component", PLAIN_THING, dict(REF), False),
    ("plain object", PLAIN_THING, {"type": "object"}, False),
    ("plain string", PLAIN_THING, {"type": "string"}, False),
    ("enum without null", PLAIN_THING, {"type": "string", "nullable": True, "enum": ["a"]}, False),
    ("nullable component, nullable wrapper", NULLABLE_THING,
     {"nullable": True, "allOf": [REF]}, True),
    ("nullable component, silent wrapper", NULLABLE_THING, {"allOf": [REF]}, True),
    ("bare $ref to a nullable component", NULLABLE_THING, dict(REF), True),
    ("oneOf with an explicit null branch", PLAIN_THING,
     {"nullable": True, "oneOf": [{"allOf": [REF]}, NULL_BRANCH]}, True),
    ("anyOf with an explicit null branch", PLAIN_THING,
     {"nullable": True, "anyOf": [{"allOf": [REF]}, NULL_BRANCH]}, True),
    # `oneOf` wants exactly one match. Two branches that both take null make
    # null match twice, and the schema rejects it although each branch says it
    # does not; `anyOf` is satisfied by the same pair.
    ("oneOf, two branches both nullable", PLAIN_THING,
     {"nullable": True, "oneOf": [{"type": "object", "nullable": True},
                                  {"type": "string", "nullable": True}]}, False),
    ("anyOf, two branches both nullable", PLAIN_THING,
     {"nullable": True, "anyOf": [{"type": "object", "nullable": True},
                                  {"type": "string", "nullable": True}]}, True),
    ("oneOf, one of two branches nullable", PLAIN_THING,
     {"nullable": True, "oneOf": [{"type": "object", "nullable": True},
                                  {"type": "string"}]}, True),
    ("oneOf over a nullable $ref and a null branch", NULLABLE_THING,
     {"nullable": True, "oneOf": [REF, NULL_BRANCH]}, False),
    ("plain nullable object", PLAIN_THING, {"type": "object", "nullable": True}, True),
    ("nullable string", PLAIN_THING, {"type": "string", "nullable": True}, True),
]


class AcceptsNull(unittest.TestCase):
    def test_every_shape_matches_oas30(self):
        for label, thing, node, expected in SHAPES:
            with self.subTest(label):
                self.assertEqual(
                    build.accepts_null(spec(thing), node),
                    expected,
                    f"{label}: OAS30Validator says null is "
                    f"{'accepted' if expected else 'rejected'} here",
                )

    def test_allOf_needs_every_branch_to_take_null(self):
        document = spec(NULLABLE_THING)
        both = {"nullable": True, "allOf": [REF, {"type": "object", "nullable": True}]}
        self.assertTrue(build.accepts_null(document, both))
        one = {"nullable": True, "allOf": [REF, {"type": "object"}]}
        self.assertFalse(build.accepts_null(document, one))

    def test_a_ref_cycle_terminates(self):
        document = {"components": {"schemas": {"Thing": {"$ref": "#/components/schemas/Thing"}}}}
        self.assertFalse(build.accepts_null(document, dict(REF)))

    def test_a_dangling_ref_is_not_null_accepting(self):
        self.assertFalse(
            build.accepts_null(spec(PLAIN_THING), {"$ref": "#/components/schemas/Nope"})
        )


class Check(unittest.TestCase):
    def setUp(self):
        self.known = dict(build.KNOWN_NOT_NULLABLE)
        build.KNOWN_NOT_NULLABLE.clear()
        self.addCleanup(self.restore_known)

    def restore_known(self):
        build.KNOWN_NOT_NULLABLE.clear()
        build.KNOWN_NOT_NULLABLE.update(self.known)

    def test_the_regression_shape_is_reported(self):
        document = spec(PLAIN_THING, thing={"nullable": True, "allOf": [REF]})
        problems = build.check_nullable_composition(document)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Holder.thing says nullable: true but does not accept null", problems[0])

    def test_the_fix_is_accepted(self):
        document = spec(NULLABLE_THING, thing={"nullable": True, "allOf": [REF]})
        self.assertEqual(build.check_nullable_composition(document), [])

    def test_a_property_that_declares_its_own_type_is_left_alone(self):
        # `nullable` on a node that carries its own `type` means what it says,
        # and there is no composition to disagree with it.
        document = spec(PLAIN_THING, thing={"type": "string", "nullable": True})
        self.assertEqual(build.check_nullable_composition(document), [])

    def test_a_property_that_never_claimed_nullable_is_left_alone(self):
        document = spec(PLAIN_THING, thing={"allOf": [REF]})
        self.assertEqual(build.check_nullable_composition(document), [])

    def test_an_allowlisted_property_is_suppressed(self):
        build.KNOWN_NOT_NULLABLE[("Holder", "thing")] = "#2189"
        document = spec(PLAIN_THING, thing={"nullable": True, "allOf": [REF]})
        self.assertEqual(build.check_nullable_composition(document), [])

    def test_a_stale_allowlist_entry_fails(self):
        build.KNOWN_NOT_NULLABLE[("Holder", "thing")] = "#2189"
        document = spec(NULLABLE_THING, thing={"nullable": True, "allOf": [REF]})
        problems = build.check_nullable_composition(document)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("accepts null now", problems[0])


class CommittedContract(unittest.TestCase):
    """The five fields, as they stand in the checked-in projection.

    `contract.json` is committed, so this runs with no Elixir toolchain and no
    export — the same reason the SDK verifier reads it. The document-level
    check runs against `dist/openapi.json` in `release-and-contract`; this is
    the half that cannot be skipped.
    """

    FIELDS = ["Agent", "AgentRequest", "AgentUpdate", "Conversation", "ConversationCreateRequest"]

    @classmethod
    def setUpClass(cls):
        cls.contract = json.loads((REPO / "sdk" / "contract" / "contract.json").read_text())

    def test_response_compositions_have_an_explicit_null_branch(self):
        for owner, field, target in [
            ("Conversation", "sandbox", "Sandbox"),
            ("Turn", "usage", "TurnUsage"),
        ]:
            with self.subTest(owner=owner, field=field):
                node = self.contract["schemas"][owner]["properties"][field]
                self.assertTrue(node["nullable"])
                self.assertEqual(node["anyOf"][0], {"allOf": [{"ref": target}]})
                self.assertEqual(node["anyOf"][1], {"enum": ["None"], "nullable": True})
        self.assertEqual(build.KNOWN_NOT_NULLABLE, {})

    def test_the_component_is_nullable(self):
        # This is the whole fix. Drop it and all five fields below stop taking
        # the null the server sends, with nothing else in the diff.
        self.assertIs(self.contract["schemas"]["PermissionPolicy"].get("nullable"), True)

    def test_every_permission_policy_field_refers_to_it_and_is_nullable(self):
        for name in self.FIELDS:
            with self.subTest(name):
                node = self.contract["schemas"][name]["properties"]["permission_policy"]
                self.assertIs(node.get("nullable"), True)
                self.assertEqual([b.get("ref") for b in node["allOf"]], ["PermissionPolicy"])

    def test_the_dynamic_verdict_map_survives_the_extraction(self):
        # The other property the extraction had to keep: a policy is an open
        # map of tool name to verdict, not a closed object with one field.
        # `agent_controller_test.exs` guards the casting half.
        extra = self.contract["schemas"]["PermissionPolicy"]["additionalProperties"]
        self.assertEqual(
            sorted(extra["oneOf"][0]["enum"]), ["ask", "auto_allow", "auto_deny"]
        )
        self.assertEqual(extra["oneOf"][1]["type"], "integer")


if __name__ == "__main__":
    unittest.main()
