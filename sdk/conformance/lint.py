#!/usr/bin/env python3
"""Check the conformance scenarios before any SDK runs them.

Three jobs, in order of how much they save:

1. **The fixtures must be responses the real server could send.** Every `json`
   body in a scenario is validated against the schema the server declares for
   that operation in `sdk/contract/contract.json` (#1411). A fixture is a
   promise about the wire, and a fixture nobody checked is how a suite goes
   green against an API that does not exist. This is the join between the two
   halves: the contract says what the shapes are, the scenarios say what a
   client does with them, and neither is allowed to drift from the other.

2. **The format must be the one the adapters implement.** Four adapters read
   these files, and a typo in a key name is otherwise four silent no-ops rather
   than one failure.

3. **The support matrix must be complete.** Every scenario needs a verdict for
   every SDK, and a skip needs an issue number. That is what keeps a gap a
   decision somebody made rather than a scenario quietly running nowhere.

Usage:
    python3 sdk/conformance/lint.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCENARIOS = HERE / "scenarios"
MATRIX = HERE / "matrix.json"
CONTRACT = ROOT / "sdk" / "contract" / "contract.json"

SDKS = ("typescript", "python", "swift", "swift-kit", "elixir")

OPS = {
    "me": set(),
    "list": {"resource"},
    "create_agent": {"attrs"},
    "get_conversation": {"conversation_id"},
    "run": {"agent", "prompt"},
    "send": {"conversation_id", "prompt"},
    "history": {"conversation_id"},
}
OP_OPTIONAL = {
    "run": {"channel_id", "client_request_id", "timeout_ms", "answer_permissions"},
    "list": set(),
}

EVENT_TYPES = {
    "conversation",
    "turn-start",
    "text",
    "thinking",
    "tool",
    "permission",
    "block",
    "event",
    "turn-end",
}

ERROR_KINDS = {
    "auth",
    "not_found",
    "validation",
    "rate_limited",
    "busy",
    "quota",
    "insufficient_credits",
    "not_ready",
    "timeout",
    "connection",
    "resolution",
    "server",
}

CONTRACTS = {
    "auth",
    "errors",
    "sse-framing",
    "reconnect",
    "run-states",
    "permissions",
    "pagination",
}

SCENARIO_KEYS = {"name", "title", "contract", "why", "client", "http", "steps", "expect"}
EXPECT_KEYS = {
    "requests",
    "requests_exactly",
    "events",
    "result",
    "error",
    "no_error",
    "value",
    "event_ids",
}
RESULT_KEYS = {
    "state",
    "text",
    "tools_used",
    "turn_number",
    "exit_code",
    "reason",
    "conversation_id",
    "status",
}
ERROR_KEYS = {
    "kind",
    "status",
    "code",
    "retryable",
    "retry_after",
    "field_errors",
    "upgrade_url",
    "partial_text",
}

NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


class Problems:
    def __init__(self) -> None:
        self.items: List[str] = []

    def add(self, where: str, message: str) -> None:
        self.items.append("  %s\n      %s" % (where, message))

    def __bool__(self) -> bool:
        return bool(self.items)


# ── validating a fixture body against the declared schema ────────────────────


def path_to_template(path: str) -> Optional[str]:
    """Map a concrete request path back to the OpenAPI template it came from.

    `/api/conversations/<uuid>/stream` is `/api/conversations/{conversation_id}/stream`.
    Matching is by segment count and by literal segments, so a template whose
    variable sits where the scenario has a literal still matches, which is the
    only way this works without a router.
    """
    parts = [p for p in path.split("/") if p]
    for template in TEMPLATES:
        segments = [p for p in template.split("/") if p]
        if len(segments) != len(parts):
            continue
        if all(
            segment.startswith("{") or segment == part
            for segment, part in zip(segments, parts)
        ):
            return template
    return None


def resolve_ref(node: Any, schemas: Dict[str, Any], seen: Optional[set] = None) -> Any:
    seen = seen or set()
    while isinstance(node, dict) and node.get("ref"):
        name = node["ref"]
        if name in seen:
            return {}
        seen.add(name)
        node = schemas.get(name, {})
    return node


def check_body(
    body: Any, schema: Any, schemas: Dict[str, Any], where: str, problems: Problems
) -> None:
    """A structural check, not a full JSON Schema implementation.

    It answers the two questions a fixture gets wrong: does it use a property
    the schema does not declare, and does it omit one the schema requires. Type
    checking stops at the primitive families, because the aim is to catch an
    invented field, not to reimplement a validator.
    """
    schema = resolve_ref(schema, schemas)
    if not isinstance(schema, dict) or not schema:
        return

    for keyword in ("oneOf", "anyOf"):
        if keyword in schema:
            # A union is satisfied if any member is; report nothing rather than
            # guess which member the fixture meant.
            return

    kind = schema.get("type")

    if kind == "array":
        if not isinstance(body, list):
            problems.add(where, "the schema says array, the fixture has %s" % type(body).__name__)
            return
        for index, item in enumerate(body):
            check_body(item, schema.get("items") or {}, schemas, "%s[%d]" % (where, index), problems)
        return

    if kind == "object" or "properties" in schema:
        if not isinstance(body, dict):
            problems.add(where, "the schema says object, the fixture has %s" % type(body).__name__)
            return
        properties = schema.get("properties") or {}
        if properties:
            for key in sorted(body):
                if key not in properties:
                    if schema.get("additionalProperties"):
                        continue
                    problems.add(
                        "%s.%s" % (where, key),
                        "no such property in the declared schema. It has: %s"
                        % ", ".join(sorted(properties)),
                    )
            for key, prop in sorted(properties.items()):
                if prop.get("required") and key not in body:
                    problems.add(
                        "%s.%s" % (where, key),
                        "the schema requires this property and the fixture omits it",
                    )
                if key in body:
                    check_body(body[key], prop, schemas, "%s.%s" % (where, key), problems)
        return

    if body is None:
        return  # nullable is common enough that a null is never the interesting failure
    families = {
        "string": str,
        "integer": int,
        "number": (int, float),
        "boolean": bool,
    }
    expected = families.get(kind or "")
    if expected and not isinstance(body, expected):
        if kind == "integer" and isinstance(body, bool):
            pass  # bool is an int in Python; fall through to the report
        elif isinstance(body, expected):
            return
        problems.add(where, "the schema says %s, the fixture has %s" % (kind, type(body).__name__))


def response_schema(
    contract: Dict[str, Any], method: str, path: str, status: int, body: Any
) -> Optional[Any]:
    template = path_to_template(path)
    if template is None:
        return None
    operation = contract["operations"].get("%s %s" % (method.upper(), template))
    if not operation:
        return None
    media = (operation.get("responses") or {}).get(str(status)) or {}
    declared = media.get("application/json")
    if declared is not None:
        return declared
    return None


# ── the scenario checks ──────────────────────────────────────────────────────


def check_scenario(scenario: Dict[str, Any], path: Path, contract: Dict[str, Any], problems: Problems) -> None:
    where = path.name
    schemas = contract["schemas"]

    unknown = sorted(set(scenario) - SCENARIO_KEYS)
    if unknown:
        problems.add(where, "unknown top-level keys: %s" % ", ".join(unknown))
    for required in ("name", "title", "contract", "why", "client", "http", "steps", "expect"):
        if required not in scenario:
            problems.add(where, "missing `%s`" % required)
            return

    name = scenario["name"]
    if name != path.stem:
        problems.add(where, "`name` is %r but the file is %r" % (name, path.stem))
    if not NAME.match(name):
        problems.add(where, "`name` must be lower-case-with-hyphens")
    if scenario["contract"] not in CONTRACTS:
        problems.add(
            where,
            "`contract` %r is not one of %s" % (scenario["contract"], ", ".join(sorted(CONTRACTS))),
        )
    if not scenario["why"].endswith("."):
        problems.add(where, "`why` should be a sentence: it is what a reviewer reads first")

    # steps
    if not scenario["steps"]:
        problems.add(where, "`steps` is empty; a scenario that asks the client to do nothing proves nothing")
    for index, step in enumerate(scenario["steps"]):
        op = step.get("op")
        if op not in OPS:
            problems.add(
                "%s steps[%d]" % (where, index),
                "unknown op %r. The vocabulary is: %s" % (op, ", ".join(sorted(OPS))),
            )
            continue
        allowed = OPS[op] | OP_OPTIONAL.get(op, set()) | {"op"}
        missing = sorted(OPS[op] - set(step))
        if missing:
            problems.add("%s steps[%d]" % (where, index), "op %r needs %s" % (op, ", ".join(missing)))
        extra = sorted(set(step) - allowed)
        if extra:
            problems.add("%s steps[%d]" % (where, index), "op %r has no field %s" % (op, ", ".join(extra)))

    # http
    for index, exchange in enumerate(scenario["http"]):
        spot = "%s http[%d]" % (where, index)
        match, respond = exchange.get("match"), exchange.get("respond")
        if not isinstance(match, dict) or not isinstance(respond, dict):
            problems.add(spot, "each exchange needs a `match` and a `respond` object")
            continue
        if "method" not in match or "path" not in match:
            problems.add(spot, "`match` needs a `method` and a `path`")
            continue
        for header in (match.get("headers") or {}):
            if header != header.lower():
                problems.add(spot, "header names in `match` must be lower-case: %r" % header)
        if "status" not in respond:
            problems.add(spot, "`respond` needs a `status`")
            continue
        if "json" in respond and "body" in respond:
            problems.add(spot, "`respond` takes `json` or `body`, not both")
        if "sse" in respond:
            if respond.get("close") not in ("end", "abort"):
                problems.add(spot, "a streaming `respond` needs `close`: \"end\" or \"abort\"")
            for chunk in respond["sse"]:
                if isinstance(chunk, dict) and set(chunk) - {"text", "delay_ms"}:
                    problems.add(spot, "an sse chunk object takes only `text` and `delay_ms`")
                elif not isinstance(chunk, (str, dict)):
                    problems.add(spot, "an sse chunk is a string or a {text, delay_ms} object")

        # The join with sdk/contract: is this a body the server could send?
        if "json" in respond:
            schema = response_schema(
                contract, match["method"], match["path"], respond["status"], respond["json"]
            )
            if schema is None:
                problems.add(
                    spot,
                    "no operation in sdk/contract/contract.json serves `%s %s` with a %s. "
                    "Either the fixture is wrong or the scenario is testing an endpoint "
                    "the server does not have."
                    % (match["method"], match["path"], respond["status"]),
                )
            else:
                check_body(respond["json"], schema, schemas, "%s http[%d].json" % (where, index), problems)

    # expect
    expect = scenario["expect"]
    unknown = sorted(set(expect) - EXPECT_KEYS)
    if unknown:
        problems.add(where, "unknown `expect` keys: %s" % ", ".join(unknown))
    if not expect:
        problems.add(where, "`expect` is empty; a scenario that asserts nothing is not a scenario")
    if "error" in expect and expect.get("no_error"):
        problems.add(where, "`expect` cannot ask for both an error and no error")
    for index, event in enumerate(expect.get("events") or []):
        if event.get("type") not in EVENT_TYPES:
            problems.add(
                "%s expect.events[%d]" % (where, index),
                "unknown event type %r. The vocabulary is: %s"
                % (event.get("type"), ", ".join(sorted(EVENT_TYPES))),
            )
    error = expect.get("error")
    if error is not None:
        unknown = sorted(set(error) - ERROR_KEYS)
        if unknown:
            problems.add(where, "unknown `expect.error` keys: %s" % ", ".join(unknown))
        if error.get("kind") not in ERROR_KINDS:
            problems.add(
                where,
                "`expect.error.kind` %r is not in the shared vocabulary: %s"
                % (error.get("kind"), ", ".join(sorted(ERROR_KINDS))),
            )
    result = expect.get("result")
    if result is not None:
        unknown = sorted(set(result) - RESULT_KEYS)
        if unknown:
            problems.add(where, "unknown `expect.result` keys: %s" % ", ".join(unknown))


def check_matrix(names: List[str], problems: Problems) -> None:
    if not MATRIX.exists():
        problems.add("matrix.json", "missing. Every scenario needs a verdict for every SDK.")
        return
    matrix = json.loads(MATRIX.read_text())
    entries = matrix.get("scenarios") or {}

    for name in names:
        entry = entries.get(name)
        if entry is None:
            problems.add(
                "matrix.json",
                "%s has no entry. Add one per SDK: \"yes\", or {\"skip\": …, \"issue\": N}." % name,
            )
            continue
        for sdk in SDKS:
            verdict = entry.get(sdk)
            if verdict is None:
                problems.add("matrix.json", "%s has no verdict for %s" % (name, sdk))
            elif verdict == "yes":
                continue
            elif isinstance(verdict, dict):
                if not verdict.get("skip"):
                    problems.add("matrix.json", "%s/%s must say why it is skipped" % (name, sdk))
                if not isinstance(verdict.get("issue"), int):
                    problems.add(
                        "matrix.json",
                        "%s/%s is skipped with no issue number. A gap that nobody filed is a gap "
                        "nobody closes." % (name, sdk),
                    )
            else:
                problems.add(
                    "matrix.json",
                    "%s/%s is %r; the only values are \"yes\" or {\"skip\", \"issue\"}"
                    % (name, sdk, verdict),
                )

    for name in sorted(set(entries) - set(names)):
        problems.add("matrix.json", "%s names no scenario in scenarios/" % name)


def main() -> int:
    if not CONTRACT.exists():
        sys.stderr.write(
            "error: %s is missing. Build it with scripts/sdk-contract/build.sh\n"
            % CONTRACT.relative_to(ROOT)
        )
        return 1
    contract = json.loads(CONTRACT.read_text())

    global TEMPLATES
    TEMPLATES = sorted(
        {operation.split(" ", 1)[1] for operation in contract["operations"]},
        key=lambda template: (template.count("{"), -len(template)),
    )

    problems = Problems()
    names = []
    for path in sorted(SCENARIOS.glob("*.json")):
        names.append(path.stem)
        try:
            scenario = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            problems.add(path.name, "is not valid JSON: %s" % error)
            continue
        check_scenario(scenario, path, contract, problems)

    if not names:
        problems.add("scenarios/", "is empty")
    check_matrix(names, problems)

    if problems:
        sys.stderr.write(
            "conformance scenarios: FAILED (%d problems)\n\n" % len(problems.items)
        )
        sys.stderr.write("\n\n".join(problems.items) + "\n")
        return 1

    print("conformance scenarios: ok (%d scenarios)" % len(names))
    return 0


TEMPLATES: List[str] = []

if __name__ == "__main__":
    raise SystemExit(main())
