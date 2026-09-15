#!/usr/bin/env python3
"""Generate FountainKit wire models from the committed contract.

Only compatibility names/order and reused value types live here. Properties,
requiredness, nullability and coding keys are read from the contract. Unknown
shapes fail rather than silently becoming an untyped field.
"""
import argparse
import copy
import difflib
import functools
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "sdk/swift/Sources/FountainKit/Models/ConversationWire.generated.swift"
# Existing public names/types, not an allowlist of supported properties.
TYPE_NAMES = {"TurnUsage": "Usage", "UsageTotal": "Usage"}
REUSED = set()
# Public nested names are source compatibility, not schema/property lists.
TYPE_NAMES.update({"SandboxCheckpoint": "Sandbox.Checkpoint",
                   "SandboxRunner": "Sandbox.RunnerRef",
                   "SandboxConversation": "SandboxDetail.SandboxConversation"})
INLINE_TYPES = {
    ("Sandbox", "checkpoint"): "SandboxCheckpoint",
    ("SandboxDetail", "checkpoint"): "SandboxCheckpoint",
    ("Sandbox", "runner"): "SandboxRunner",
    ("SandboxDetail", "runner"): "SandboxRunner",
}
# Preserve the pre-generation optional Swift API and permissive decoder for
# these already-public properties, even where the contract now requires them.
# New properties always inherit requiredness directly from the contract.
OPTIONAL_COMPAT = {
    ("Sandbox", "sprite_name"), ("Sandbox", "status"),
    ("SandboxDetail", "sprite_name"), ("SandboxDetail", "status"),
    ("SandboxDetail", "conversations"), ("SandboxRunner", "online"),
    ("Runner", "created_at"),
    ("SandboxConversation", "status"), ("SandboxConversation", "mid_turn"),
}
ENUM_TYPES = {
    ("Conversation", "runtime"): "Runtime",
    ("Conversation", "status"): "ConversationStatus",
    ("Conversation", "source"): "ConversationSource",
    ("Conversation", "sandbox_api_access"): "SandboxAPIAccess",
    ("ConversationCreateRequest", "sandbox_api_access"): "SandboxAPIAccess",
    ("ConversationCreateRequest", "sandbox_mode"): "SandboxMode",
    ("Turn", "status"): "TurnStatus", ("Turn", "origin"): "TurnOrigin",
}
for owner in ("Sandbox", "SandboxDetail"):
    ENUM_TYPES.update({(owner, "status"): "SandboxStatus", (owner, "mode"): "SandboxMode",
                       (owner, "provider"): "SandboxProvider"})
ENUM_TYPES.update({("SandboxConversation", "status"): "ConversationStatus",
                   ("SandboxConversation", "runtime"): "Runtime",
                   ("ConversationTreeNode", "status"): "ConversationStatus",
                   ("ConversationTreeNode", "source"): "ConversationSource"})
# Swift argument ordering is source API. New fields append automatically.
INIT_ORDER = "agent_id prompt title vault_id environment_id permission_policy images sprite_name sandbox_mode sandbox_api_access sandbox_id channel_id fresh".split()

# Resource-family names, source API differences and initializer order.
RESOURCE_ROOTS = [
    'Agent',
    'AgentVersion',
    'AgentUpdate',
    'Environment',
    'EnvironmentUpdate',
    'Vault',
    'VaultUpdate',
    'Secret',
    'Connection',
    'ConnectionProvider',
    'Teammate',
    'TeamSchedule',
    'TeamScheduleUpdateRequest',
    'ApiKey',
    'ApiKeyCreatedResponse',
    'AuditEvent',
    'SearchHit',
    'Catalog',
    'ApplyResult',
    'AdminUser',
    'AdminSandbox',
    'AdminEvent',
]

SCHEMA_PATHS = {
    'Catalog': ['CatalogResponse', 'properties', 'data'],
    'AdminEvent': ['AdminEventListResponse', 'properties', 'data', 'items'],
}

TYPE_NAMES.update({
    'AgentUpdate': 'AgentInput',
    'EnvironmentUpdate': 'EnvironmentInput',
    'VaultUpdate': 'VaultInput',
    'TeamScheduleUpdateRequest': 'TeamScheduleInput',
    'ApiKey': 'APIKey',
    'ApiKeyCreatedResponse': 'CreatedAPIKey',
    'ApplySecretResult': 'ApplyResult.SecretResult',
    'AgentSkillsItem': 'Skill',
    'TeammatePresence': 'Teammate.Presence',
    'TeammateLastTurn': 'Teammate.LastTurn',
    'TeammatePreview': 'Teammate.Preview',
    'CatalogSandboxProviders': 'Catalog.SandboxProviders',
    'CatalogApps': 'Catalog.Apps',
})

INLINE_TYPES.update({
    ('Agent', 'skills_item'): 'AgentSkillsItem',
    ('AgentUpdate', 'skills_item'): 'AgentSkillsItem',
})

ENUM_TYPES.update({
    ('Environment', 'networking_type'): 'NetworkingType',
    ('EnvironmentUpdate', 'networking_type'): 'NetworkingType',
    ('AdminUser', 'role'): 'UserRole',
    ('AdminSandbox', 'provider'): 'SandboxProvider',
    ('AdminSandbox', 'status'): 'SandboxStatus',
    ('Connection', 'status'): 'ConnectionStatus',
    ('Agent', 'runtime'): 'Runtime',
    ('Agent', 'sandbox_provider'): 'SandboxProvider',
    ('Agent', 'sandbox_mode'): 'SandboxMode',
    ('AgentUpdate', 'runtime'): 'Runtime',
    ('AgentUpdate', 'sandbox_provider'): 'SandboxProvider',
    ('AgentUpdate', 'sandbox_mode'): 'SandboxMode',
    ('SearchHit', 'kind'): 'SearchHitKind',
    ('TeammatePresence', 'state'): 'PresenceState',
    ('TeammateLastTurn', 'status'): 'TurnStatus',
})

TYPE_OVERRIDES = {
    ('Environment', 'packages'): 'JSONValue',
    ('Environment', 'networking_config'): 'JSONValue',
    # Repositories stay dynamic: the typed Repository schema is deliberately
    # unreachable here, matching the deleted handwritten `[JSONValue]?`.
    ('Environment', 'repositories'): '[JSONValue]',
    ('Environment', 'metadata'): 'JSONValue',
    ('EnvironmentUpdate', 'packages'): 'JSONValue',
    ('EnvironmentUpdate', 'networking_config'): 'JSONValue',
    ('EnvironmentUpdate', 'repositories'): '[JSONValue]',
    ('EnvironmentUpdate', 'metadata'): 'JSONValue',
    ('Vault', 'metadata'): 'JSONValue',
    ('VaultUpdate', 'metadata'): 'JSONValue',
    ('AdminEvent', 'metadata'): 'JSONValue',
    ('Agent', 'mcp_servers'): 'JSONValue',
    ('Agent', 'metadata'): 'JSONValue',
    ('AgentVersion', 'config'): 'JSONValue',
    ('AgentUpdate', 'mcp_servers'): 'JSONValue',
    ('AgentUpdate', 'metadata'): 'JSONValue',
    ('AuditEvent', 'metadata'): 'JSONValue',
    ('ApplyResult', 'errors'): 'JSONValue',
    ('ApplySecretResult', 'errors'): 'JSONValue',
}

OPTIONAL_COMPAT.update({
    ('AdminSandbox', 'status'),
    ('AdminUser', 'role'),
    ('AgentVersion', 'config'),
    ('AgentVersion', 'inserted_at'),
    ('ApiKey', 'created_at'),
    ('ApiKey', 'prefix'),
    ('ApiKeyCreatedResponse', 'name'),
    ('ApiKeyCreatedResponse', 'prefix'),
    ('AuditEvent', 'inserted_at'),
    ('Catalog', 'apps'),
    ('Catalog', 'models'),
    ('Catalog', 'package_managers'),
    ('Catalog', 'runtimes'),
    ('Catalog', 'sandbox_providers'),
    ('CatalogSandboxProviders', 'default'),
    ('CatalogSandboxProviders', 'enabled'),
    ('Connection', 'account_email'),
    ('Connection', 'env_key'),
    ('Connection', 'scopes'),
    ('Connection', 'status'),
    ('ConnectionProvider', 'configured'),
    ('ConnectionProvider', 'connect_url'),
    ('ConnectionProvider', 'env_key'),
    ('ConnectionProvider', 'name'),
    ('ConnectionProvider', 'slug'),
    ('SearchHit', 'snippet'),
    ('SearchHit', 'ts'),
    ('Secret', 'environment_id'),
    ('TeamSchedule', 'enabled'),
    ('TeamSchedule', 'one_off'),
    ('TeammateLastTurn', 'id'),
    ('TeammateLastTurn', 'prompt'),
    ('TeammateLastTurn', 'status'),
    ('TeammateLastTurn', 'turn_number'),
    ('TeammatePresence', 'label'),
})

# Properties this SDK exposes for the first time, on types that already
# shipped handwritten. A payload an older server emits decoded before
# generation; honouring contract requiredness here would fail the whole
# response instead of the one field. Only wholly new types follow the
# contract directly.
OPTIONAL_COMPAT.update({
    ('Catalog', 'first_request'),
    ('CatalogMcpServersItem', 'dcr'),
    ('CatalogMcpServersItem', 'name'),
    ('CatalogMcpServersItem', 'slug'),
    ('CatalogMcpServersItem', 'url'),
    ('CatalogMcpServersItem', 'verified_on'),
    ('ConnectionProvider', 'kind'),
    ('ConnectionProvider', 'platform'),
    ('ConnectionProvider', 'redirect_uri'),
    ('ConnectionProvider', 'scopes'),
    ('ConnectionProvider', 'token_hosts'),
})

# The escape hatch for the decode rule alone: a property this SDK may expose as
# non-Optional because no deployed server can emit that type without it. It
# says nothing about source compatibility, so it cannot authorize flipping a
# property the last release published as Optional. Empty by design — an entry is a claim about every
# server in the field, not somewhere to send a property that merely looks
# safe. `Catalog.first_request` is the shape of the argument and is pinned
# anyway, because a partial `first_request` was never possible.
REQUIRED_BY_CONTRACT = set()

INPUT_ORDERS = {
    'VaultUpdate': ['name', 'description', 'metadata'],
    'EnvironmentUpdate': ['name', 'packages', 'env_vars', 'setup_script', 'setup_timeout_seconds', 'networking_type', 'networking_config', 'repositories', 'metadata'],
    'TeamScheduleUpdateRequest': ['cron', 'prompt', 'name', 'one_off', 'enabled'],
    'AgentUpdate': ['name', 'description', 'system', 'model', 'runtime', 'runtime_command', 'sandbox_provider', 'sandbox_mode', 'environment_id', 'permission_policy', 'skills', 'mcp_servers', 'metadata', 'allowed_vault_ids', 'allowed_environment_ids'],
    'AgentSkillsItem': ['name', 'content', 'source', 'ref'],
}

RELEASED_MODELS = "sdk/swift/Sources/FountainKit/Models"
DECLARATION = re.compile(r"(\s*)(?:public\s+)?(?:final\s+)?(?:struct|enum|class|actor|extension)\s+(\w+)")
# A property whose name is a Swift keyword is published escaped — `default` is
# the one today — and the generated side spells it the same way, so both sides
# normalize to the bare name rather than missing each other.
PROPERTY = re.compile(r"\s*public var `?(\w+)`?:\s*([^{]+)")


def public_properties(text, into):
    """Record `{(type, property): decodes from an absent key}` from Swift source.

    Both shapes these models have used are read the same way: a nested type
    declared inside its parent, which is how they were handwritten, and one
    declared in an extension, which is how they are generated. A type keeps the
    same key across the migration that moved it.
    """
    scopes = []
    for line in text.splitlines():
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        while scopes and indent <= scopes[-1][0]:
            scopes.pop()
        declaration = DECLARATION.match(line)
        if declaration:
            scopes.append((indent, declaration.group(2)))
            continue
        prop = PROPERTY.match(line)
        if prop and scopes:
            key = (".".join(scope for _, scope in scopes), prop.group(1))
            # Optional in any source wins: the permissive reading is the one
            # that keeps a payload from an older server decoding.
            into[key] = into.get(key, False) or prop.group(2).strip().endswith("?")
    return into


def released(*args):
    """Read a path out of the last release, which is the only immutable record.

    The baseline has to be immutable with respect to the change being checked.
    The working tree is not: a change that makes a property required and
    commits the regenerated file would offer its own candidate as the record of
    what shipped and authorize itself. A tag cannot move.
    """
    def git(*command):
        done = subprocess.run(["git", "-C", str(ROOT), *command], text=True, capture_output=True)
        if done.returncode:
            raise ValueError(
                f"Cannot read the last release (git {' '.join(command)}): "
                f"{done.stderr.strip()}. This needs the release tags: a shallow "
                "checkout has to fetch them (fetch-tags with fetch-depth: 0).")
        return done.stdout
    tag = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*").strip()
    return git(*[argument.replace("<tag>", tag) for argument in args])


@functools.lru_cache(maxsize=None)
def released_requiredness():
    """Which properties the last released server always sent.

    Absence from the released *SDK* is not evidence that the released *server*
    could not emit a shape: `CatalogMcpServersItem` is a contract shape from
    before v0.17.1 that the v0.17.1 Swift models simply did not expose. So the
    question "can an older server produce this, and can it omit this key" is
    asked of the released contract, not of the released Swift.
    """
    contract = json.loads(released("show", "<tag>:sdk/contract/contract.json"))
    generator = Generator(contract, baseline=True)
    generator.build()
    return {(owner, key): bool(value.get("required")) and not value.get("nullable")
            for owner, fields in generator.models.items()
            for key, _, _, value in fields}


@functools.lru_cache(maxsize=None)
def released_properties():
    """What the last released SDK exposes, read from its tag.

    The baseline has to be immutable with respect to the change being checked.
    The committed output is not: a change that makes a property required and
    commits the regenerated file would offer its own candidate as the record of
    what shipped and authorize itself. A tag cannot move, and "already shipped"
    means released, which is what the rule in contributing/swift-wire-models.md
    is about. Every model the release carries counts, wherever it lived then —
    `Teammate` shipped handwritten and is generated now.
    """
    shipped = {}
    for path in released("ls-tree", "-r", "--name-only", "<tag>", "--", RELEASED_MODELS).split():
        public_properties(released("show", f"<tag>:{path}"), shipped)
    if not shipped:
        raise ValueError(f"The last release carries no public Swift properties under {RELEASED_MODELS}")
    return shipped


def camel(key):
    first, *rest = key.split("_")
    return first + "".join({"id": "ID", "ids": "IDs", "ip": "IP", "api": "API", "url": "URL",
                            "uri": "URI", "uris": "URIs"}.get(p, p.title()) for p in rest)


class Generator:
    def __init__(self, contract, baseline=False):
        # A baseline generator reads an older contract to answer one question:
        # which properties did that server always send. It applies no pins,
        # runs no guard, and tolerates roots the older contract never had.
        self.baseline = baseline
        self.schemas = copy.deepcopy(contract["schemas"])
        for name, path in SCHEMA_PATHS.items():
            node = contract["schemas"]
            for key in path:
                if key not in node:
                    if baseline:
                        node = None
                        break
                    raise ValueError(f"The contract has no {name} at {'.'.join(path)}")
                node = node[key]
            if node is not None:
                self.schemas[name] = node
        self.pending = ["Conversation", "Turn", "ConversationCreateRequest", "ImageInput", "TurnUsage", "UsageAccounting", "SandboxDetail", "Runner", "ConversationTreeNode"] + RESOURCE_ROOTS
        self.done = set()
        self.nested = {}
        self.dependencies = {}
        self.input_roots = {"ConversationCreateRequest", "ImageInput", "AgentUpdate", "EnvironmentUpdate", "VaultUpdate", "TeamScheduleUpdateRequest"}
        self.encodable = set(self.input_roots)

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
        if (owner, key) in TYPE_OVERRIDES:
            return TYPE_OVERRIDES[owner, key]
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
            name = INLINE_TYPES.get((owner, key), owner + camel(key)[0].upper() + camel(key)[1:])
            # Reused inline models must remain the same shape. A contract
            # divergence needs an explicit migration, never first-wins output.
            shape = {k: v for k, v in node.items() if k not in {"required", "nullable"}}
            if name in self.nested and self.nested[name] != shape:
                raise ValueError(f"Incompatible reused inline shape: {name}")
            self.nested[name] = shape
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
        if owner == "Secret":
            # One public Secret serves both environment and vault endpoints.
            other = self.schemas["VaultSecret"]["properties"]
            for key in props.keys() & other.keys():
                shape = lambda node: {k: v for k, v in node.items() if k != "required"}
                if shape(props[key]) != shape(other[key]):
                    raise ValueError(f"Incompatible secret field: {key}")
            props = {
                key: dict(value, required=props.get(key, {}).get("required", False)
                          and other.get(key, {}).get("required", False))
                for key, value in {**props, **other}.items()
            }
        if owner == "TurnUsage":
            # Usage is the public superset used for both a turn and a total.
            # New total fields must propagate too; incompatible shared names
            # need a migration rather than silently choosing one definition.
            for key, value in self.schemas["UsageTotal"]["properties"].items():
                if key in props:
                    shape = lambda node: {k: v for k, v in node.items() if k != "required"}
                    if shape(props[key]) != shape(value):
                        raise ValueError(f"Incompatible usage field: {key}")
                else:
                    props[key] = dict(value, required=False)
        fields = []
        for key, value in sorted(props.items()):
            if not self.baseline and (owner, key) in OPTIONAL_COMPAT:
                value["required"] = False
            swift = "permissionPolicyValues" if key == "permission_policy" else ("`default`" if key == "default" else camel(key))
            fields.append((key, swift, self.type(owner, key, value), value))
        return fields

    def model(self, owner, fields):
        name = TYPE_NAMES.get(owner, owner)
        request = owner == "ConversationCreateRequest"
        encodable = owner in self.encodable
        decodable = owner not in self.input_roots
        nullable = [f for f in fields if f[3].get("nullable")]
        # Keep Optional source APIs, but retain a separate null state anywhere
        # a generated input accepts null, including shared response models.
        input_fields = encodable and (request or bool(nullable))
        props = {key: value for key, _, _, value in fields}
        if decodable:
            conform = "Sendable, Codable, Hashable" if encodable else "Sendable, Decodable, Hashable"
        else:
            conform = "Sendable, Encodable"
        if decodable and ("id" in props or owner == "Teammate"):
            conform += ", Identifiable"
        parent, _, short_name = name.rpartition(".")
        lines = [f"public struct {short_name or name}: {conform} {{"]
        for key, swift, typ, value in fields:
            optional = not value.get("required", False) or value.get("nullable", False)
            if input_fields and optional:
                lines += [f"  private var _{swift}: ConversationInputField<{typ}> = .omitted",
                          f"  public var {swift}: {typ}? {{",
                          f"    get {{ _{swift}.value }}",
                          f"    set {{ _{swift} = newValue.map(ConversationInputField.value) ?? .omitted }}", "  }"]
            else:
                lines += [f'  public var {swift}: {typ}{"?" if optional else ""}']
        if owner == "Teammate":
            lines += ["  public var id: String { agentID }"]
        if "permission_policy" in props:
            lines += ["", "  /// String verdicts for compatibility. Use permissionPolicyValues for numeric policy values.",
                      "  public var permissionPolicy: [String: String]? {",
                      "    get { permissionPolicyValues?.compactMapValues(\\.stringValue) }",
                      "    set { permissionPolicyValues = newValue?.mapValues(JSONValue.string) }", "  }"]
        if encodable:
            order = INIT_ORDER if request else INPUT_ORDERS.get(owner, [])
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
        rendered = "\n".join(lines + ["}", ""])
        if parent:
            return f"extension {parent} {{\n" + "\n".join("  " + line for line in rendered.splitlines()) + "\n}\n"
        return rendered

    def compatibility_failures(self, shipped, always_sent):
        """The direction OPTIONAL_COMPAT exists for, which nothing else guards.

        These structs have no custom `init(from:)`, so one missing key fails the
        whole enclosing response rather than the property. Two questions, one
        per baseline, because neither answers the other:

        `always_sent` is the released contract, and answers whether an older
        server can produce this shape at all and whether it can omit the key.
        This is the decode rule. It has to be asked of the contract rather than
        of the released SDK, because absence from the SDK is not absence from
        the server: `CatalogMcpServersItem` is a shape the v0.17.1 server
        already emitted and the v0.17.1 Swift models simply did not expose, so
        a required property added to it breaks an older server's whole
        `Catalog` response while looking like a wholly new type.

        `shipped` is the released Swift, and answers whether this SDK already
        published the property as Optional. That is a source-compatibility
        question: flipping `x?` to `x` breaks a consumer's code even when every
        server always sends the key.

        Pinning the property satisfies both, and it is the only thing that
        satisfies the second. `test_optional_compat_pins_reach_a_live_property`
        only checks that pins still name a property, never that a property that
        needs one has it.
        """
        published = {owner for owner, _ in shipped}
        emitted = {owner for owner, _ in always_sent}
        failures = []
        for owner, fields in self.models.items():
            # An input-only model is encoded and never decoded, so no response
            # from an older server is in question. Pinning a request property
            # would be worse than useless: it would let a field the server
            # requires be omitted, and the request rejected instead.
            if owner in self.input_roots:
                continue
            name = TYPE_NAMES.get(owner, owner)
            for key, swift, _, value in fields:
                if not value.get("required", False) or value.get("nullable", False):
                    continue
                # Each rule is answered on its own, and a property can owe
                # both. A shape the released contract never described cannot
                # come back from a released server, so it takes contract
                # requiredness; anything it did describe must survive the keys
                # that server could leave out.
                if (owner in emitted and not always_sent.get((owner, key), False)
                        and (owner, key) not in REQUIRED_BY_CONTRACT):
                    failures.append(f"{name}.{swift} is required here and the last release could omit it")
                # REQUIRED_BY_CONTRACT does not reach this rule. It claims that
                # every deployed server sends the key, which can establish that
                # decoding is safe but cannot make an already-public `T?`
                # becoming `T` source-compatible. There is deliberately no
                # override here: keep the pin, and let a change that really
                # means to drop a published Optional add its own door and say so.
                if name in published and shipped.get((name, swift.strip("`")), False):
                    failures.append(f"{name}.{swift} shipped Optional and the contract now requires it")
        return failures

    def build(self):
        # Discover the whole graph before emitting models: a response model
        # visited first can also be used by a later request field.
        models = {}
        while self.pending:
            owner = self.pending.pop(0)
            if owner in self.done:
                continue
            self.done.add(owner)
            node = self.schemas.get(owner, self.nested.get(owner))
            if node is None:
                if self.baseline:
                    continue  # The release never carried this shape.
                raise ValueError(f"The contract has no schema for {owner}")
            models[owner] = self.fields(owner, node)
        # Kept for the compatibility tables' own guard: a pin naming a property
        # the contract no longer has stops applying silently.
        self.models = models
        return models

    def render(self):
        models = self.build()
        failures = self.compatibility_failures(released_properties(), released_requiredness())
        if failures:
            raise ValueError(
                "A response from a server older than this change would fail to decode: "
                + "; ".join(sorted(failures))
                + ". Pin each in OPTIONAL_COMPAT and add the omission that proves it, "
                "or record in REQUIRED_BY_CONTRACT that no deployed server omits it.")
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
