#!/usr/bin/env python3
"""Generate the FountainKit conversation boundary from the committed contract.

Only compatibility names/order and reused value types live here. Properties,
requiredness, nullability and coding keys are read from the contract. Unknown
shapes fail rather than silently becoming an untyped field.
"""
import argparse
import copy
import difflib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "sdk/swift/Sources/FountainKit/Models/ConversationWire.generated.swift"
# Existing public names/types, not an allowlist of supported properties.
TYPE_NAMES = {"TurnUsage": "Usage", "UsageTotal": "Usage"}
REUSED = {"Sandbox"}
ENUM_TYPES = {
    ("Conversation", "runtime"): "Runtime",
    ("Conversation", "status"): "ConversationStatus",
    ("Conversation", "source"): "ConversationSource",
    ("Conversation", "sandbox_api_access"): "SandboxAPIAccess",
    ("ConversationCreateRequest", "sandbox_api_access"): "SandboxAPIAccess",
    ("ConversationCreateRequest", "sandbox_mode"): "SandboxMode",
    ("Turn", "status"): "TurnStatus", ("Turn", "origin"): "TurnOrigin",
}
# Swift argument ordering is source API. New fields append automatically.
INIT_ORDER = "agent_id prompt title vault_id environment_id permission_policy images sprite_name sandbox_mode sandbox_api_access sandbox_id channel_id fresh".split()


def camel(key):
    first, *rest = key.split("_")
    return first + "".join(p.upper() if p in {"id", "api", "url"} else p.title() for p in rest)


class Generator:
    def __init__(self, contract):
        self.schemas = contract["schemas"]
        self.pending = ["Conversation", "Turn", "ConversationCreateRequest", "ImageInput", "TurnUsage", "UsageAccounting"]
        self.done = set()
        self.nested = {}
        self.dependencies = {}
        self.encodable = {"ConversationCreateRequest", "ImageInput"}

    def reference(self, owner, ref):
        if ref == "PermissionPolicy":
            return "[String: JSONValue]"
        if ref == "UsageTotal":
            ref = "TurnUsage"
        self.dependencies.setdefault(owner, set()).add(ref)
        if ref not in REUSED:
            self.pending.append(ref)
        return TYPE_NAMES.get(ref, ref)

    def type(self, owner, key, node):
        if (owner, key) in ENUM_TYPES:
            return ENUM_TYPES[owner, key]
        if "ref" in node:
            return self.reference(owner, node["ref"])
        if "allOf" in node and len(node["allOf"]) == 1:
            return self.type(owner, key, node["allOf"][0])
        for composition in ("anyOf", "oneOf"):
            if composition in node:
                branches = [b for b in node[composition] if b.get("enum") != ["None"]]
                if len(branches) == 1:
                    return self.type(owner, key, branches[0])
                raise ValueError(f"Unsupported union at {owner}.{key}")
        kind = node.get("type")
        if kind == "array":
            return f'[{self.type(owner, key + "_item", node["items"])}]'
        if kind == "object":
            if "additionalProperties" in node:
                extra = node["additionalProperties"]
                value = "JSONValue" if extra is True or extra == {} else self.type(owner, key + "_value", extra)
                return f"[String: {value}]"
            if not node.get("properties"):
                return "[String: JSONValue]"
            name = owner + camel(key)[0].upper() + camel(key)[1:]
            self.nested[name] = node
            return self.reference(owner, name)
        if kind == "string":
            return "Date" if node.get("format") == "date-time" else "String"
        if kind in {"boolean", "integer", "number"}:
            return {"boolean": "Bool", "integer": "Int", "number": "Double"}[kind]
        if not node or set(node) <= {"required", "nullable"}:
            return "JSONValue"
        raise ValueError(f"Unsupported shape at {owner}.{key}: {node}")

    def fields(self, owner, node):
        props = copy.deepcopy(node["properties"])
        if owner == "Conversation":
            # Existing Conversation is also the team-history view. Read that
            # extension from its own schema; make it optional outside history.
            for branch in self.schemas["TeammateConversation"]["allOf"]:
                for key, value in branch.get("properties", {}).items():
                    props[key] = dict(value, required=False)
        fields = []
        for key, value in sorted(props.items()):
            swift = "permissionPolicyValues" if key == "permission_policy" else camel(key)
            fields.append((key, swift, self.type(owner, key, value), value))
        return fields

    def model(self, owner, fields):
        name = TYPE_NAMES.get(owner, owner)
        request = owner == "ConversationCreateRequest"
        encodable = owner in self.encodable
        decodable = owner not in {"ConversationCreateRequest", "ImageInput"}
        nullable = [f for f in fields if f[3].get("nullable")]
        # Keep Optional source APIs, but retain a separate null state anywhere
        # a generated input accepts null, including shared response models.
        input_fields = encodable and (request or bool(nullable))
        props = {key: value for key, _, _, value in fields}
        if decodable:
            conform = "Sendable, Codable, Hashable" if encodable else "Sendable, Decodable, Hashable"
        else:
            conform = "Sendable, Encodable"
        if decodable and "id" in props:
            conform += ", Identifiable"
        lines = [f"public struct {name}: {conform} {{"]
        for key, swift, typ, value in fields:
            optional = not value.get("required", False) or value.get("nullable", False)
            if input_fields and optional:
                lines += [f"  private var _{swift}: ConversationInputField<{typ}> = .omitted",
                          f"  public var {swift}: {typ}? {{",
                          f"    get {{ _{swift}.value }}",
                          f"    set {{ _{swift} = newValue.map(ConversationInputField.value) ?? .omitted }}", "  }"]
            else:
                lines += [f'  public var {swift}: {typ}{"?" if optional else ""}']
        if "permission_policy" in props:
            lines += ["", "  /// String verdicts for compatibility. Use permissionPolicyValues for numeric policy values.",
                      "  public var permissionPolicy: [String: String]? {",
                      "    get { permissionPolicyValues?.compactMapValues(\\.stringValue) }",
                      "    set { permissionPolicyValues = newValue?.mapValues(JSONValue.string) }", "  }"]
        if encodable:
            order = INIT_ORDER if request else []
            ordered = sorted(fields, key=lambda f: (order.index(f[0]) if f[0] in order else len(order), f[0]))
            lines += ["", "  public init("]
            params = []
            for key, swift, typ, value in ordered:
                optional = not value.get("required", False) or value.get("nullable", False)
                if key == "permission_policy":
                    swift, typ = "permissionPolicy", "[String: String]"
                params.append(f'    {swift}: {typ}{"? = nil" if optional else ""}')
            lines += [p + ("," if i < len(params)-1 else "") for i, p in enumerate(params)]
            lines += ["  ) {"]
            # Calling a computed input-property setter uses self. Initialize
            # every required stored property first, without changing argument order.
            assignments = sorted(ordered, key=lambda f: input_fields and (
                not f[3].get("required", False) or f[3].get("nullable", False)))
            for key, swift, typ, value in assignments:
                if key == "permission_policy":
                    lines += ["    self.permissionPolicyValues = permissionPolicy?.mapValues(JSONValue.string)"]
                else:
                    lines += [f"    self.{swift} = {swift}"]
            lines += ["  }"]
        lines += ["", "  enum CodingKeys: String, CodingKey {"]
        lines += [f'    case {swift} = "{key}"' for key, swift, _, _ in fields]
        lines += ["  }"]
        if input_fields:
            lines += ["", "  /// Fields for which the API accepts an explicit JSON null.", "  public enum NullableField: Sendable {"]
            lines += [f"    case {swift}" for _, swift, _, _ in nullable]
            lines += ["  }", "", "  /// Send null. Assigning the property nil again restores omission.", "  public mutating func setNull(_ field: NullableField) {", "    switch field {"]
            lines += [f"    case .{swift}: _{swift} = .null" for _, swift, _, _ in nullable]
            lines += ["    }", "  }", "", "  public func encode(to encoder: any Encoder) throws {", "    var container = encoder.container(keyedBy: CodingKeys.self)"]
            for _, swift, _, value in fields:
                if not value.get("required", False) or value.get("nullable", False):
                    lines += [f"    try _{swift}.encode(into: &container, forKey: .{swift})"]
                else:
                    lines += [f"    try container.encode({swift}, forKey: .{swift})"]
            lines += ["  }"]
            if decodable:
                lines += ["", "  public init(from decoder: any Decoder) throws {",
                          "    let container = try decoder.container(keyedBy: CodingKeys.self)"]
                for _, swift, typ, value in fields:
                    if not value.get("required", False) or value.get("nullable", False):
                        lines += [f"    _{swift} = try ConversationInputField.decode(from: container, forKey: .{swift})"]
                    else:
                        lines += [f"    {swift} = try container.decode({typ}.self, forKey: .{swift})"]
                lines += ["  }"]
        return "\n".join(lines + ["}", ""])

    def render(self):
        # Discover the whole graph before emitting models: a response model
        # visited first can also be used by a later request field.
        models = {}
        while self.pending:
            owner = self.pending.pop(0)
            if owner in self.done:
                continue
            self.done.add(owner)
            models[owner] = self.fields(owner, self.schemas.get(owner, self.nested.get(owner)))
        pending = list(self.encodable)
        while pending:
            owner = pending.pop()
            for dependency in self.dependencies.get(owner, set()) - self.encodable:
                self.encodable.add(dependency)
                pending.append(dependency)
        result = ["// Generated by scripts/sdk-contract/generate-swift.py. Do not edit.", "import Foundation", ""]
        result.extend(self.model(owner, fields) for owner, fields in models.items())
        return "\n".join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    contract = json.loads((ROOT / "sdk/contract/contract.json").read_text())
    # The SDK's pinned Swift formatter is part of generation, so its output
    # obeys the same formatting gate as handwritten code on macOS and Linux.
    raw = Generator(contract).render()
    formatted = subprocess.run(["swift", "format", "format"], input=raw, text=True, check=True, capture_output=True).stdout
    if args.check:
        old = OUTPUT.read_text() if OUTPUT.exists() else ""
        if old != formatted:
            sys.stderr.writelines(difflib.unified_diff(old.splitlines(True), formatted.splitlines(True), fromfile=str(OUTPUT), tofile="regenerated"))
            return 1
    else:
        OUTPUT.write_text(formatted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
