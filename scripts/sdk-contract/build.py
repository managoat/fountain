#!/usr/bin/env python3
"""Turn the served OpenAPI document into the SDK wire contract.

The server is the only place the API is described. `mix openapi.export` renders
that description to `dist/openapi.json`; this script canonicalises that file and
projects it down to `sdk/contract/contract.json`, which is checked in and is
what the SDK verifier reads.

Two files rather than one, because they answer different questions:

  dist/openapi.json      the whole document, vendor extensions off. Not checked
                         in — it is rebuilt from the server and it moves with
                         every prose edit and every release.
  sdk/contract/contract.json
                         shape only: operations, schemas, requiredness, enums.
                         Checked in, so an SDK check needs no Elixir toolchain,
                         and a diff on it is exactly "the wire changed".

What the projection deliberately drops is as important as what it keeps.
Descriptions, summaries, tags and `info.version` are not part of the wire, so a
docs pass or a release bump must not diff this file — if it did, the diff would
stop meaning anything and reviewers would stop reading it.

The one trap worth naming: a property with a `default` is NOT required.
`openapi-typescript` emits such properties as non-optional, which is why
`sdk/typescript/src/schemas.ts` carries an `Optional<>` re-relaxation for
`ScheduleInput`. Requiredness here comes from the schema's `required` list and
nothing else; `has_default` is recorded beside it. `--check` asserts this on
every default-carrying property so the bug cannot be baked into three more
languages.

Usage:
    python3 scripts/sdk-contract/build.py            # write both files
    python3 scripts/sdk-contract/build.py --check    # write dist/openapi.json,
                                                     # then fail rather than
                                                     # write a stale contract
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "dist" / "openapi.json"
CONTRACT = ROOT / "sdk" / "contract" / "contract.json"
OMISSIONS = ROOT / "sdk" / "contract" / "omissions.json"
MANIFESTS = ROOT / "sdk" / "contract" / "manifests"

CONTRACT_VERSION = 1

METHODS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")

# Everything a projected type node may carry. Ordered so a rendered node reads
# the way the schema does; `sort_keys` is off for nodes and on for the file, so
# both orders are fixed.
_REF = re.compile(r"^#/components/schemas/(.+)$")


def die(message: str) -> None:
    sys.stderr.write(f"error: {message}\n")
    raise SystemExit(1)


def ref_name(node: Any) -> Optional[str]:
    if isinstance(node, dict) and isinstance(node.get("$ref"), str):
        match = _REF.match(node["$ref"])
        if match:
            return match.group(1)
        die(f"unsupported $ref {node['$ref']!r}: only component schemas are projected")
    return None


def canonical(value: Any) -> Any:
    """Recursively sort every object key.

    open_api_spex renders through Jason, which encodes a map in its internal
    order. That is stable for a given key set on a given OTP release, so the
    export already reproduces byte for byte here — but it is stable by accident,
    not by contract, and it is not something to discover on an OTP bump. Sorting
    makes determinism a property of this script.
    """
    if isinstance(value, dict):
        return {key: canonical(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [canonical(item) for item in value]
    return value


def dump(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def project_type(node: Any) -> Dict[str, Any]:
    """One property or parameter schema, reduced to what a client must agree on."""
    if not isinstance(node, dict):
        return {}

    out: Dict[str, Any] = {}

    ref = ref_name(node)
    if ref:
        out["ref"] = ref

    if isinstance(node.get("type"), str):
        out["type"] = node["type"]
    if isinstance(node.get("format"), str):
        out["format"] = node["format"]
    if node.get("nullable") is True:
        out["nullable"] = True
    if isinstance(node.get("enum"), list):
        out["enum"] = sorted(str(value) for value in node["enum"])

    if isinstance(node.get("items"), dict):
        out["items"] = project_type(node["items"])

    # An inline object — a response body declared in the `operation` macro
    # rather than as a named schema — carries its properties here, and dropping
    # them left the projection saying `{"type": "object"}`: a shape nothing can
    # disagree with. That is how the 402 on POST /api/conversations looked like
    # an undeclared body when the server declares `error` and `upgrade_url`
    # perfectly well (#1427). Requiredness is read the same way as in
    # `project_schema`: from the sibling `required` list, never from a default.
    properties = node.get("properties")
    if isinstance(properties, dict):
        required = set(node.get("required") or [])
        projected = {}
        for prop, sub in properties.items():
            entry = project_type(sub)
            entry["required"] = prop in required
            if isinstance(sub, dict) and "default" in sub:
                entry["has_default"] = True
            projected[prop] = entry
        out["properties"] = projected

    for keyword in ("oneOf", "anyOf", "allOf"):
        if isinstance(node.get(keyword), list):
            out[keyword] = [project_type(member) for member in node[keyword]]

    extra = node.get("additionalProperties")
    if isinstance(extra, dict):
        out["additionalProperties"] = project_type(extra)
    elif isinstance(extra, bool):
        out["additionalProperties"] = extra

    return out


def project_schema(name: str, schema: Dict[str, Any]) -> Dict[str, Any]:
    required = set(schema.get("required") or [])

    out: Dict[str, Any] = {}
    if isinstance(schema.get("type"), str):
        out["type"] = schema["type"]
    # A named schema may be nullable itself, and that is the difference between
    # a `$ref` to it accepting null and refusing it (#1899). `project_type`
    # has always recorded this on a property; without it here the projection
    # said nullability was part of the contract while a whole half of it was
    # invisible, so the fix for a null-refusing field diffed to nothing.
    if schema.get("nullable") is True:
        out["nullable"] = True
    if isinstance(schema.get("enum"), list):
        out["enum"] = sorted(str(value) for value in schema["enum"])

    properties = schema.get("properties")
    if isinstance(properties, dict):
        projected: Dict[str, Any] = {}
        for prop, node in properties.items():
            entry = project_type(node)
            # Requiredness comes from the schema's `required` list, never from
            # the presence of a default. See the module docstring.
            entry["required"] = prop in required
            if isinstance(node, dict) and "default" in node:
                entry["has_default"] = True
            projected[prop] = entry
        out["properties"] = projected

        unknown = sorted(required - set(properties))
        if unknown:
            die(f"schema {name}: required names {unknown} that it has no property for")
    elif required:
        die(f"schema {name}: has a required list but no properties")

    for keyword in ("oneOf", "anyOf", "allOf"):
        if isinstance(schema.get(keyword), list):
            out[keyword] = [project_type(member) for member in schema[keyword]]

    if isinstance(schema.get("items"), dict):
        out["items"] = project_type(schema["items"])

    extra = schema.get("additionalProperties")
    if isinstance(extra, dict):
        out["additionalProperties"] = project_type(extra)
    elif isinstance(extra, bool):
        out["additionalProperties"] = extra

    return out


def project_operation(path: str, method: str, operation: Dict[str, Any]) -> Dict[str, Any]:
    out: Dict[str, Any] = {"operation_id": operation.get("operationId")}

    path_params: List[str] = []
    query: Dict[str, Any] = {}
    header: Dict[str, Any] = {}
    for parameter in operation.get("parameters") or []:
        if not isinstance(parameter, dict):
            continue
        name = parameter.get("name")
        where = parameter.get("in")
        entry = project_type(parameter.get("schema") or {})
        entry["required"] = bool(parameter.get("required"))
        if where == "path":
            path_params.append(str(name))
        elif where == "query":
            query[str(name)] = entry
        elif where == "header":
            header[str(name)] = entry

    out["path_params"] = sorted(path_params)
    if query:
        out["query_params"] = query
    if header:
        out["header_params"] = header

    body = operation.get("requestBody")
    if isinstance(body, dict):
        content = body.get("content") or {}
        media = {}
        for media_type, spec in sorted(content.items()):
            media[media_type] = project_type((spec or {}).get("schema") or {})
        out["request_body"] = {"required": bool(body.get("required")), "content": media}

    responses: Dict[str, Any] = {}
    for status, response in sorted((operation.get("responses") or {}).items()):
        if not isinstance(response, dict):
            continue
        content = response.get("content") or {}
        media = {}
        for media_type, spec in sorted(content.items()):
            media[media_type] = project_type((spec or {}).get("schema") or {})
        responses[str(status)] = media
    out["responses"] = responses

    return out


def project(spec: Dict[str, Any]) -> Dict[str, Any]:
    schemas = (spec.get("components") or {}).get("schemas") or {}
    operations: Dict[str, Any] = {}

    for path, item in (spec.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        shared = item.get("parameters") or []
        for method in METHODS:
            operation = item.get(method)
            if not isinstance(operation, dict):
                continue
            merged = dict(operation)
            merged["parameters"] = list(shared) + list(operation.get("parameters") or [])
            operations[f"{method.upper()} {path}"] = project_operation(path, method, merged)

    return {
        "contract_version": CONTRACT_VERSION,
        "openapi": spec.get("openapi"),
        "security": canonical(spec.get("security") or []),
        "operations": operations,
        "schemas": {
            name: project_schema(name, schema)
            for name, schema in schemas.items()
            if isinstance(schema, dict)
        },
    }


# ── the omissions allowlist ──────────────────────────────────────────────────


def load_json(path: Path, what: str) -> Any:
    if not path.exists():
        die(f"{what} is missing: {path.relative_to(ROOT)}")
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as error:
        die(f"{what} is not valid JSON ({path.relative_to(ROOT)}): {error}")


def covered_operations() -> Dict[str, List[str]]:
    """Which SDKs claim which operations, from the checked-in manifests."""
    claims: Dict[str, List[str]] = {}
    for manifest_path in sorted(MANIFESTS.glob("*.json")):
        manifest = load_json(manifest_path, "SDK manifest")
        sdk = manifest.get("sdk") or manifest_path.stem
        for operation in manifest.get("operations") or []:
            claims.setdefault(str(operation), []).append(str(sdk))
    return claims


def check_coverage(contract: Dict[str, Any]) -> List[str]:
    """Every operation is claimed by an SDK or written down as an omission.

    This is what gives the allowlist teeth. A new endpoint fails here until
    somebody either wires it into a client or records, in one line, why no
    client models it.
    """
    omissions = load_json(OMISSIONS, "the omissions allowlist")
    patterns = omissions.get("omit") or []
    claims = covered_operations()

    problems: List[str] = []
    used = set()

    for operation in sorted(contract["operations"]):
        if operation in claims:
            continue
        match = None
        for index, rule in enumerate(patterns):
            for glob in rule.get("operations") or []:
                if fnmatch.fnmatchcase(operation, glob):
                    match = index
                    break
            if match is not None:
                break
        if match is None:
            problems.append(
                f"  {operation}\n"
                "      no SDK manifest claims it and no omissions entry covers it"
            )
        else:
            used.add(match)

    for index, rule in enumerate(patterns):
        if index not in used:
            globs = ", ".join(rule.get("operations") or [])
            problems.append(
                f"  omissions entry [{globs}] matches nothing the API still serves\n"
                "      delete it, or fix the pattern"
            )

    stale = sorted(set(claims) - set(contract["operations"]))
    for operation in stale:
        who = ", ".join(sorted(claims[operation]))
        problems.append(f"  {operation}\n      claimed by {who} but the API no longer serves it")

    return problems


def check_defaults(contract: Dict[str, Any]) -> List[str]:
    """A `default` must never have been read as requiredness (the #1408 trap)."""
    problems = []
    for name, schema in sorted(contract["schemas"].items()):
        for prop, entry in sorted((schema.get("properties") or {}).items()):
            if entry.get("has_default") and entry.get("required"):
                problems.append(
                    f"  {name}.{prop} carries a default and is projected as required.\n"
                    "      A default means the client may omit it. Fix the projection,\n"
                    "      or drop the default from the server schema."
                )
    return problems


def resolve_ref(spec: Dict[str, Any], node: Any) -> Any:
    """Follow `$ref` within this document, or None if it does not resolve.

    Siblings of a `$ref` are ignored in 3.0. None rather than `{}` for a
    dangling or cyclic pointer, because an empty schema accepts everything and
    a broken one should not be mistaken for it.
    """
    seen = set()
    while isinstance(node, dict) and "$ref" in node:
        pointer = node["$ref"]
        if pointer in seen or not isinstance(pointer, str) or not pointer.startswith("#/"):
            return None
        seen.add(pointer)
        target: Any = spec
        for part in pointer[2:].split("/"):
            part = part.replace("~1", "/").replace("~0", "~")
            if not isinstance(target, dict) or part not in target:
                return None
            target = target[part]
        node = target
    return node


def accepts_null(spec: Dict[str, Any], node: Any, depth: int = 0) -> bool:
    """Does this schema node accept `null` under OpenAPI 3.0?

    3.0 has no `"type": "null"`. `nullable: true` relaxes the type of the schema
    it sits on and NOTHING else, so a node that borrows its shape from a
    composition keyword must also be given null by that composition:

      * `allOf` — every branch must accept null, because the instance has to
        satisfy all of them.
      * `anyOf` — at least one branch must, because the instance has to
        satisfy one.
      * `oneOf` — exactly one branch must. Two branches that both take null
        (`[{type: object, nullable}, {type: string, nullable}]`) make null
        match twice, and `oneOf` refuses an instance that matches more than
        one branch, so a schema like that rejects null even though every
        branch says it does not.

    The trap this exists for (#1899): a wrapper written as
    `{"nullable": true, "allOf": [{"$ref": ...}]}` reads as nullable and is not.
    The wrapper's own `nullable` is vacuous — it carries no `type` to relax —
    and the referenced schema is where `type: object` lives, so that is the
    branch that refuses null. Adding `type: object` to the wrapper does not
    help: the branch still refuses. Either the referenced schema carries
    `nullable: true` itself, or a union needs an explicit null-only branch.

    Verified against `openapi-schema-validator` 0.9.0's `OAS30Validator` on
    every shape in `scripts/ci/test_sdk_contract_nullable.py`.
    """
    node = resolve_ref(spec, node)
    if not isinstance(node, dict) or depth > 20:
        return False

    for keyword, admits in (
        ("allOf", lambda results: all(results)),
        ("anyOf", lambda results: any(results)),
        ("oneOf", lambda results: sum(results) == 1),
    ):
        branches = node.get(keyword)
        if isinstance(branches, list) and branches:
            results = [accepts_null(spec, branch, depth + 1) for branch in branches]
            if not admits(results):
                return False
            # A composition that admits null still has to get past this node's
            # own constraints, which is the `type`/`enum` pair below.

    # A node with no `type` of its own constrains no type, so null gets past it
    # whether or not it bothered to say `nullable`. A node that declares a
    # `type` refuses null unless `nullable: true` relaxes it. This is the
    # asymmetry the trap lives in: the wrapper has no type, so its `nullable`
    # buys nothing, and the branch that HAS the type never saw the flag.
    if "type" in node and node.get("nullable") is not True:
        return False
    # `enum` narrows whatever the type allows, null included.
    values = node.get("enum")
    if isinstance(values, list) and None not in values:
        return False
    return True


# The original Conversation.sandbox / Turn.usage exceptions were repaired in
# #2189. Keep the ratchet empty: future regressions must fail the build.
KNOWN_NOT_NULLABLE = {}


def check_nullable_composition(spec: Dict[str, Any]) -> List[str]:
    """A property that says `nullable: true` must actually accept null (#1899).

    Walks every property of every named schema. One that declares itself
    nullable and then delegates its shape to `allOf`/`anyOf`/`oneOf`/`$ref` is
    checked for whether the composition admits null too, because a generated
    client and any standards-based validator read the document, not our casting
    layer — `OpenApiSpex` resolves null before it ever reaches the composition,
    which is why the whole Elixir suite stayed green while the published
    contract refused a value the server returns.
    """
    problems = []
    broken = set()
    schemas = ((spec.get("components") or {}).get("schemas") or {})
    for name, schema in sorted(schemas.items()):
        if not isinstance(schema, dict):
            continue
        for prop, node in sorted((schema.get("properties") or {}).items()):
            if not isinstance(node, dict) or node.get("nullable") is not True:
                continue
            if not any(k in node for k in ("allOf", "anyOf", "oneOf", "$ref")):
                continue  # declares its own type; `nullable` means what it says
            if accepts_null(spec, node):
                continue
            broken.add((name, prop))
            if (name, prop) in KNOWN_NOT_NULLABLE:
                continue
            problems.append(
                f"  {name}.{prop} says nullable: true but does not accept null.\n"
                "      In OpenAPI 3.0 `nullable` relaxes the type of the node it sits\n"
                "      on, so a composed shape refuses null unless the composition\n"
                "      does too. Put `nullable: true` on the referenced schema, or\n"
                "      give the union an explicit null branch. Adding `type: object`\n"
                "      to the wrapper does not work."
            )

    for name, prop in sorted(set(KNOWN_NOT_NULLABLE) - broken):
        problems.append(
            f"  {name}.{prop} accepts null now, and is still on KNOWN_NOT_NULLABLE.\n"
            "      Delete the line: the list is a record of what is broken, and a\n"
            "      stale entry hides the next one."
        )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of writing when the artifact or the contract is stale",
    )
    parser.add_argument("--spec", default=str(SPEC), help="path to the exported OpenAPI document")
    args = parser.parse_args()

    spec_path = Path(args.spec)
    if not spec_path.exists():
        die(
            f"{spec_path} does not exist.\n"
            "  Build it first: scripts/sdk-contract/build.sh\n"
            "  (or, from apps/fountain, `mix openapi.export`)"
        )

    raw = json.loads(spec_path.read_text())
    canonical_spec = dump(canonical(raw))
    contract = project(canonical(raw))
    rendered = dump(contract)

    # Over `raw`, not the projection: the projection records the wrapper's own
    # `nullable` and so reads as correct in exactly the case this catches.
    problems = check_defaults(contract) + check_nullable_composition(raw)

    # The artifact is written in both modes. `mix openapi.export` renders it in
    # the encoder's order, so it is never canonical when it lands and there
    # would be nothing for a check to do but rewrite it. The TypeScript
    # generate step reads it straight after this, and what --check is about is
    # the committed files below.
    spec_path.write_text(canonical_spec)

    if args.check:
        on_disk = CONTRACT.read_text() if CONTRACT.exists() else ""
        if on_disk != rendered:
            problems.append(
                "  sdk/contract/contract.json is stale — the server's wire contract moved.\n"
                "      Rebuild it: scripts/sdk-contract/build.sh\n"
                "      Then update every SDK the diff touches; see CONTRIBUTING.md."
            )
        problems.extend(check_coverage(contract))
        if problems:
            sys.stderr.write("SDK wire contract: FAILED\n\n" + "\n".join(problems) + "\n")
            return 1
        counts = f"{len(contract['operations'])} operations, {len(contract['schemas'])} schemas"
        print(f"SDK wire contract: ok ({counts})")
        return 0

    if problems:
        sys.stderr.write("SDK wire contract: FAILED\n\n" + "\n".join(problems) + "\n")
        return 1

    CONTRACT.parent.mkdir(parents=True, exist_ok=True)
    CONTRACT.write_text(rendered)
    print(
        f"wrote {spec_path.relative_to(ROOT)} and {CONTRACT.relative_to(ROOT)} "
        f"({len(contract['operations'])} operations, {len(contract['schemas'])} schemas)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
