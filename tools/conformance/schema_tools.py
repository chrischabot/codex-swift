#!/usr/bin/env python3
"""Codex app-server schema helpers for local conformance gates."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def methods_and_params(schema_dir: Path) -> tuple[set[str], dict[str, dict[str, object]]]:
    root = json.loads((schema_dir / "ClientRequest.json").read_text())
    definitions = root.get("definitions", {})
    methods: set[str] = set()
    params_by_method: dict[str, dict[str, object]] = {}

    for entry in root.get("oneOf", []):
        props = entry.get("properties", {})
        method_schema = props.get("method", {})
        method_values = []
        if isinstance(method_schema.get("const"), str):
            method_values.append(method_schema["const"])
        if isinstance(method_schema.get("enum"), list):
            method_values.extend(v for v in method_schema["enum"] if isinstance(v, str))
        params_schema = props.get("params")
        request_requires_params = "params" in entry.get("required", [])

        for method in method_values:
            methods.add(method)
            ref = None
            fields: list[str] = []
            required: list[str] = []
            if isinstance(params_schema, dict) and isinstance(params_schema.get("$ref"), str):
                ref = params_schema["$ref"].removeprefix("#/definitions/")
                definition = definitions.get(ref, {})
                if isinstance(definition, dict):
                    fields = sorted((definition.get("properties") or {}).keys())
                    required = sorted(definition.get("required") or [])
            params_by_method[method] = {
                "paramsRef": ref,
                "fields": fields,
                "required": required,
                "requestRequiresParams": request_requires_params,
            }

    return methods, params_by_method


def pin_for(codex_tree: Path, client_request: Path) -> str:
    try:
        rev = subprocess.check_output(
            ["git", "-C", str(codex_tree), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if rev:
            return rev
    except Exception:
        pass
    return "schema-sha256:" + hashlib.sha256(client_request.read_bytes()).hexdigest()


def write_golden(codex_tree: Path, schema_dir: Path, golden_dir: Path, pin: str) -> None:
    methods, params_by_method = methods_and_params(schema_dir)
    client_request = schema_dir / "ClientRequest.json"
    golden_dir.mkdir(parents=True, exist_ok=True)

    (golden_dir / "client-methods.txt").write_text(
        "".join(f"{method}\n" for method in sorted(methods))
    )
    (golden_dir / "client-method-fields.json").write_text(
        json.dumps(params_by_method, indent=2, sort_keys=True) + "\n"
    )
    manifest = {
        "pin": pin,
        "schema": "codex-rs/app-server-protocol/schema/json/ClientRequest.json",
        "clientRequestSha256": hashlib.sha256(client_request.read_bytes()).hexdigest(),
        "methodCount": len(methods),
    }
    (golden_dir / "schema-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    (golden_dir / "typescript-manifest.json").write_text(
        json.dumps(typescript_manifest(codex_tree, schema_dir), indent=2, sort_keys=True) + "\n"
    )


def _relative_to_codex(codex_tree: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(codex_tree.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def typescript_manifest(codex_tree: Path, schema_dir: Path) -> dict[str, object]:
    """Return a deterministic manifest of the pinned generated TypeScript surface."""
    typescript_dir = schema_dir.parent / "typescript"
    if not typescript_dir.is_dir():
        raise FileNotFoundError(f"generated TypeScript schema directory missing: {typescript_dir}")
    files = []
    for path in sorted(typescript_dir.rglob("*.ts")):
        rel = path.relative_to(typescript_dir).as_posix()
        data = path.read_bytes()
        files.append({
            "path": rel,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    if not files:
        raise FileNotFoundError(f"generated TypeScript schema directory is empty: {typescript_dir}")
    json_files = [
        path for path in schema_dir.rglob("*.json")
        if not path.name.startswith("codex_app_server_protocol")
    ]
    ts_stems = {Path(entry["path"]).stem for entry in files if isinstance(entry.get("path"), str)}
    missing_type_names = sorted({
        path.stem for path in json_files
        if path.stem not in ts_stems and not path.stem.startswith("JSONRPC")
    })
    return {
        "schema": _relative_to_codex(codex_tree, typescript_dir),
        "fileCount": len(files),
        "totalBytes": sum(int(entry["bytes"]) for entry in files),
        "jsonSchemaTypeCount": len(json_files),
        "jsonSchemaTypesMissingGeneratedTypeScript": missing_type_names,
        "files": files,
    }


def _case_bodies(client_request_source: str) -> dict[str, str]:
    matches = list(re.finditer(r'case\s+"([^"]+)":', client_request_source))
    bodies: dict[str, str] = {}
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(client_request_source)
        bodies[match.group(1)] = client_request_source[start:end]
    return bodies


def swift_method_param_types(repo_root: Path) -> dict[str, str]:
    source = (repo_root / "Sources/ProtocolModel/ClientRequest.swift").read_text()
    out: dict[str, str] = {}
    for method, body in _case_bodies(source).items():
        match = re.search(r"paramsAllowingEmpty\(\s*([A-Za-z_][A-Za-z0-9_]*)\.self", body, re.S)
        if not match:
            match = re.search(r"\btry\s+p\(\s*([A-Za-z_][A-Za-z0-9_]*)\.self", body, re.S)
        if match:
            out[method] = match.group(1)
    return out


def swift_struct_fields(repo_root: Path) -> dict[str, list[str]]:
    source = "\n".join(path.read_text() for path in (repo_root / "Sources/ProtocolModel").glob("*.swift"))
    out: dict[str, list[str]] = {}
    for match in re.finditer(r"public\s+struct\s+([A-Za-z_][A-Za-z0-9_]*)[^{]*\{", source):
        name = match.group(1)
        depth = 1
        index = match.end()
        while index < len(source) and depth:
            char = source[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            index += 1
        body = source[match.end():index - 1]
        fields = []
        for field in re.finditer(
            r"\bpublic\s+var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:",
            body,
        ):
            line_end = body.find("\n", field.end())
            if line_end == -1:
                line_end = len(body)
            if "{" not in body[field.end():line_end]:
                fields.append(field.group(1))
        fields = sorted(set(fields))
        out[name] = fields
    return out


def swift_field_report(repo_root: Path, params_by_method: dict[str, dict[str, object]]) -> dict[str, object]:
    method_types = swift_method_param_types(repo_root)
    struct_fields = swift_struct_fields(repo_root)
    typed: dict[str, object] = {}
    failures: list[str] = []

    for method, type_name in sorted(method_types.items()):
        schema = params_by_method.get(method)
        if not schema:
            continue
        params_ref = schema.get("paramsRef")
        schema_fields = set(schema.get("fields") or [])
        swift_fields = set(struct_fields.get(type_name, []))
        if params_ref is None:
            failures.append(f"{method}: Swift parses {type_name}, but schema has no params ref")
            continue
        if type_name != params_ref:
            failures.append(f"{method}: Swift parses {type_name}, schema uses {params_ref}")
        missing = sorted(schema_fields - swift_fields)
        extra = sorted(swift_fields - schema_fields)
        if missing:
            failures.append(f"{method}: {type_name} missing schema fields {missing}")
        typed[method] = {
            "schemaParamsRef": params_ref,
            "swiftParamsType": type_name,
            "schemaFields": sorted(schema_fields),
            "swiftFields": sorted(swift_fields),
            "missingInSwift": missing,
            "extraInSwift": extra,
        }

    return {
        "typedMethodCount": len(typed),
        "typedMethods": typed,
        "failures": failures,
    }


def _camel_case_variant(variant: str) -> str:
    return variant[:1].lower() + variant[1:] if variant else variant


def client_response_types(codex_tree: Path) -> dict[str, tuple[str | None, str]]:
    source = (
        codex_tree / "codex-rs/app-server-protocol/src/protocol/common.rs"
    ).read_text()
    pattern = re.compile(
        r"(?P<variant>[A-Za-z_][A-Za-z0-9_]*)"
        r"(?:\s*=>\s*\"(?P<wire>[^\"]+)\")?\s*\{"
        r".*?response:\s*(?P<response>[A-Za-z0-9_:]+),",
        re.S,
    )
    out: dict[str, tuple[str | None, str]] = {}
    for match in pattern.finditer(source):
        method = match.group("wire") or _camel_case_variant(match.group("variant"))
        response = match.group("response")
        if "::" in response:
            namespace, type_name = response.split("::", 1)
        else:
            namespace, type_name = None, response
        out[method] = (namespace, type_name)
    return out


def _json_schema_path(codex_tree: Path, namespace: str | None, type_name: str) -> Path:
    schema_root = codex_tree / "codex-rs/app-server-protocol/schema/json"
    if namespace:
        return schema_root / namespace / f"{type_name}.json"
    return schema_root / f"{type_name}.json"


def _object_schema(
    properties: dict[str, object] | None = None,
    required: list[str] | None = None,
) -> dict[str, object]:
    props = properties or {}
    return {"type": "object", "properties": props, "required": list(props.keys()) if required is None else required}


def _nullable(schema: dict[str, object]) -> dict[str, object]:
    return {"anyOf": [schema, {"type": "null"}]}


def _source_derived_response_schema(namespace: str | None, type_name: str) -> dict[str, object] | None:
    """Schemas for response types that are present in Rust/TS source but not emitted as JSON files.

    Keep this table intentionally small and boring: each entry mirrors a concrete
    `JsonSchema` response struct in `app-server-protocol/src/protocol`.
    """
    key = (namespace or "", type_name)
    empty_responses = {
        ("v2", "EnvironmentAddResponse"),
        ("", "FuzzyFileSearchSessionStartResponse"),
        ("", "FuzzyFileSearchSessionUpdateResponse"),
        ("", "FuzzyFileSearchSessionStopResponse"),
        ("v2", "FuzzyFileSearchSessionStartResponse"),
        ("v2", "UpdateResponse"),
        ("v2", "StopResponse"),
        ("v2", "ProcessSpawnResponse"),
        ("v2", "ProcessWriteStdinResponse"),
        ("v2", "ProcessKillResponse"),
        ("v2", "ProcessResizePtyResponse"),
        ("v2", "ThreadBackgroundTerminalsCleanResponse"),
        ("v2", "ThreadRealtimeStartResponse"),
        ("v2", "ThreadRealtimeAppendAudioResponse"),
        ("v2", "ThreadRealtimeAppendTextResponse"),
        ("v2", "ThreadRealtimeStopResponse"),
        ("v2", "AppendAudioResponse"),
        ("v2", "AppendTextResponse"),
    }
    if key in empty_responses:
        return _object_schema({}, [])

    if key in {
        ("v2", "RemoteControlEnableResponse"),
        ("v2", "RemoteControlDisableResponse"),
        ("v2", "RemoteControlStatusReadResponse"),
    }:
        return _object_schema({
            "status": {"type": "string", "enum": ["disabled", "connecting", "connected", "errored"]},
            "serverName": {"type": "string"},
            "installationId": {"type": "string"},
            "environmentId": _nullable({"type": "string"}),
        })

    if key in {
        ("v2", "ThreadIncrementElicitationResponse"),
        ("v2", "ThreadDecrementElicitationResponse"),
    }:
        return _object_schema({"count": {"type": "integer"}, "paused": {"type": "boolean"}})

    if key in {
        ("v2", "MemoryResetResponse"),
        ("v2", "ThreadMemoryModeSetResponse"),
    }:
        return _object_schema({}, [])

    if key == ("v2", "CollaborationModeListResponse"):
        return _object_schema({"data": {"type": "array", "items": True}})

    if key in {("v2", "ThreadGoalSetResponse"), ("v2", "ThreadGoalGetResponse")}:
        goal = _object_schema({
            "threadId": {"type": "string"},
            "objective": {"type": "string"},
            "status": {"type": "string", "enum": ["active", "paused", "budgetLimited", "complete"]},
            "tokenBudget": _nullable({"type": "integer"}),
            "tokensUsed": {"type": "integer"},
            "timeUsedSeconds": {"type": "integer"},
            "createdAt": {"type": "integer"},
            "updatedAt": {"type": "integer"},
        })
        return _object_schema({"goal": _nullable(goal) if key[1] == "ThreadGoalGetResponse" else goal})

    if key == ("v2", "ThreadGoalClearResponse"):
        return _object_schema({"cleared": {"type": "boolean"}})

    if key in {("v2", "ThreadTurnsListResponse"), ("v2", "ThreadTurnsItemsListResponse")}:
        return _object_schema({
            "data": {"type": "array", "items": True},
            "nextCursor": _nullable({"type": "string"}),
            "backwardsCursor": _nullable({"type": "string"}),
        })

    if key == ("v2", "ThreadRealtimeListVoicesResponse"):
        return _object_schema({"voices": {"type": "array", "items": True}})

    if key == ("v2", "MockExperimentalMethodResponse"):
        return _object_schema({"echoed": _nullable({"type": "string"})})

    if key in {("", "GetAuthStatusResponse"), ("v1", "GetAuthStatusResponse")}:
        return _object_schema({
            "authMethod": _nullable({"type": "string"}),
            "authToken": _nullable({"type": "string"}),
            "requiresOpenaiAuth": _nullable({"type": "boolean"}),
        })

    if key in {("", "GitDiffToRemoteResponse"), ("v1", "GitDiffToRemoteResponse")}:
        return _object_schema({"sha": {"type": "string"}, "diff": {"type": "string"}})

    if key in {("", "GetConversationSummaryResponse"), ("v1", "GetConversationSummaryResponse")}:
        return _object_schema({
            "summary": _object_schema({
                "conversationId": {"type": "string"},
                "path": {"type": "string"},
                "preview": {"type": "string"},
                "timestamp": _nullable({"type": "string"}),
                "updatedAt": _nullable({"type": "string"}),
                "modelProvider": {"type": "string"},
                "cwd": {"type": "string"},
                "cliVersion": {"type": "string"},
                "source": {"anyOf": [
                    {"type": "string", "enum": ["cli", "vscode", "exec", "mcp", "unknown"]},
                    {"type": "object"},
                ]},
                "gitInfo": _nullable(_object_schema({
                    "sha": _nullable({"type": "string"}),
                    "branch": _nullable({"type": "string"}),
                    "origin_url": _nullable({"type": "string"}),
                })),
            }),
        })

    return None


def response_schema_alternatives(
    codex_tree: Path, namespace: str | None, type_name: str
) -> tuple[list[dict[str, object]], str | None]:
    path = _json_schema_path(codex_tree, namespace, type_name)
    if not path.exists():
        schema = _source_derived_response_schema(namespace, type_name)
        if schema is None:
            return [], f"missing schema {path.relative_to(codex_tree)}"
    else:
        schema = json.loads(path.read_text())

    def object_shape(node: dict[str, object]) -> dict[str, object] | None:
        props = node.get("properties")
        required = node.get("required") or []
        if isinstance(props, dict):
            return {
                "required": {k for k in required if isinstance(k, str)},
                "all": set(props.keys()),
                "schema": node,
                "definitions": schema.get("definitions") or {},
            }
        if node.get("type") == "object":
            return {
                "required": set(),
                "all": set(),
                "schema": node,
                "definitions": schema.get("definitions") or {},
            }
        return None

    alternatives: list[dict[str, object]] = []
    if isinstance(schema.get("oneOf"), list):
        for entry in schema["oneOf"]:
            if isinstance(entry, dict):
                shape = object_shape(entry)
                if shape is not None:
                    alternatives.append(shape)
    else:
        shape = object_shape(schema)
        if shape is not None:
            alternatives.append(shape)

    if not alternatives:
        return [], f"non-object schema {path.relative_to(codex_tree)}"
    return alternatives, None


def swift_explicit_generic_methods(repo_root: Path) -> set[str]:
    source = (repo_root / "Sources/ProtocolModel/GenericResponses.swift").read_text()
    match = re.search(
        r"explicitDefaultMethods:\s*Set<String>\s*=\s*\[(.*?)\]",
        source,
        re.S,
    )
    if not match:
        return set()
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def _object_literal_keys(expr: str) -> set[str] | None:
    start = expr.find(".object([")
    if start == -1:
        return None
    index = start + len(".object(")
    depth = 0
    keys: set[str] = set()
    while index < len(expr):
        char = expr[index]
        if char == "[":
            depth += 1
            index += 1
            continue
        if char == "]":
            depth -= 1
            if depth == 0:
                return keys
            index += 1
            continue
        if char == '"' and depth == 1:
            end = index + 1
            escaped = False
            while end < len(expr):
                if escaped:
                    escaped = False
                elif expr[end] == "\\":
                    escaped = True
                elif expr[end] == '"':
                    break
                end += 1
            key = expr[index + 1:end]
            probe = end + 1
            while probe < len(expr) and expr[probe].isspace():
                probe += 1
            if probe < len(expr) and expr[probe] == ":":
                keys.add(key)
            index = end + 1
            continue
        index += 1
    return None


def _balanced_object_literal(expr: str) -> str | None:
    start = expr.find(".object([")
    if start == -1:
        if ".object([:])" in expr:
            return ".object([:])"
        return None
    index = start + len(".object(")
    depth = 0
    while index < len(expr):
        char = expr[index]
        if char in "[(":
            depth += 1
        elif char in "])":
            depth -= 1
            if depth == 0:
                end = index + 1
                while end < len(expr) and expr[end].isspace():
                    end += 1
                if end < len(expr) and expr[end] == ")":
                    end += 1
                return expr[start:end]
        index += 1
    return None


def _split_top_level(s: str) -> list[str]:
    out: list[str] = []
    start = 0
    depth = 0
    in_string = False
    escaped = False
    for index, char in enumerate(s):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "[(":
            depth += 1
        elif char in "])":
            depth -= 1
        elif char == "," and depth == 0:
            piece = s[start:index].strip()
            if piece:
                out.append(piece)
            start = index + 1
    piece = s[start:].strip()
    if piece:
        out.append(piece)
    return out


def _top_level_colon(s: str) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index, char in enumerate(s):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "[(":
            depth += 1
        elif char in "])":
            depth -= 1
        elif char == ":" and depth == 0:
            return index
    return -1


def _parse_swift_jsonvalue(expr: str, constants: dict[str, object] | None = None) -> object:
    expr = expr.strip().rstrip(",")
    if constants is not None and expr in constants:
        return constants[expr]
    if expr == ".null":
        return None
    if expr == ".bool(false)":
        return False
    if expr == ".bool(true)":
        return True
    m = re.fullmatch(r"\.int\((-?\d+)\)", expr)
    if m:
        return int(m.group(1))
    m = re.fullmatch(r'\.string\("((?:[^"\\]|\\.)*)"\)', expr, re.S)
    if m:
        return bytes(m.group(1), "utf-8").decode("unicode_escape")
    if expr.startswith(".array([") and expr.endswith("])"):
        inner = expr[len(".array(["):-2].strip()
        if not inner:
            return []
        return [_parse_swift_jsonvalue(part, constants) for part in _split_top_level(inner)]
    if expr == ".object([:])":
        return {}
    if expr.startswith(".object([") and expr.endswith("])"):
        inner = expr[len(".object(["):-2].strip()
        if not inner:
            return {}
        obj: dict[str, object] = {}
        for part in _split_top_level(inner):
            colon = _top_level_colon(part)
            if colon == -1:
                raise ValueError(f"could not parse object entry: {part}")
            key_expr = part[:colon].strip()
            if not (key_expr.startswith('"') and key_expr.endswith('"')):
                raise ValueError(f"could not parse object key: {key_expr}")
            key = bytes(key_expr[1:-1], "utf-8").decode("unicode_escape")
            obj[key] = _parse_swift_jsonvalue(part[colon + 1:], constants)
        return obj
    raise ValueError(f"unsupported JSONValue expression: {expr[:120]}")


def swift_generic_default_keys(repo_root: Path) -> dict[str, set[str]]:
    source = (repo_root / "Sources/ProtocolModel/GenericResponses.swift").read_text()
    switch_start = source.find("switch method")
    if switch_start == -1:
        return {}
    source = source[switch_start:]
    constants: dict[str, set[str]] = {
        "empty": set(),
        "emptyDataCursor": {"data", "nextCursor"},
        "emptyDataCursorBackwards": {"data", "nextCursor", "backwardsCursor"},
    }
    blocks = re.finditer(
        r"\n\s*case\s+(?P<labels>.*?):(?P<body>.*?)(?=\n\s*case\s+|\n\s*default:)",
        source,
        re.S,
    )
    out: dict[str, set[str]] = {}
    for block in blocks:
        methods = re.findall(r'"([^"]+)"', block.group("labels"))
        body = block.group("body")
        return_match = re.search(r"\breturn\s+(.+)", body, re.S)
        if not return_match:
            continue
        expr = return_match.group(1).strip()
        keys = _object_literal_keys(expr)
        if keys is None:
            name = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", expr)
            if name:
                keys = constants.get(name.group(1))
        if keys is None:
            continue
        for method in methods:
            out[method] = set(keys)
    return out


def swift_generic_default_values(repo_root: Path) -> dict[str, object]:
    full_source = (repo_root / "Sources/ProtocolModel/GenericResponses.swift").read_text()
    source = full_source
    switch_start = source.find("switch method")
    if switch_start == -1:
        return {}
    source = source[switch_start:]
    constants: dict[str, object] = {
        "empty": {},
        "emptyDataCursor": {"data": [], "nextCursor": None},
        "emptyDataCursorBackwards": {"data": [], "nextCursor": None, "backwardsCursor": None},
    }
    for match in re.finditer(r"private\s+static\s+let\s+([A-Za-z_][A-Za-z0-9_]*):\s*JSONValue\s*=", full_source):
        name = match.group(1)
        literal = _balanced_object_literal(full_source[match.end():])
        if literal is None:
            continue
        try:
            constants[name] = _parse_swift_jsonvalue(literal, constants)
        except ValueError:
            pass
    blocks = re.finditer(
        r"\n\s*case\s+(?P<labels>.*?):(?P<body>.*?)(?=\n\s*case\s+|\n\s*default:)",
        source,
        re.S,
    )
    out: dict[str, object] = {}
    for block in blocks:
        methods = re.findall(r'"([^"]+)"', block.group("labels"))
        body = block.group("body")
        return_match = re.search(r"\breturn\s+(.+)", body, re.S)
        if not return_match:
            continue
        expr = return_match.group(1).strip()
        value: object | None = None
        literal = _balanced_object_literal(expr)
        if literal is not None:
            value = _parse_swift_jsonvalue(literal, constants)
        else:
            name = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", expr)
            if name:
                value = constants.get(name.group(1))
        if value is None:
            continue
        for method in methods:
            out[method] = value
    return out


def _schema_type_allows(schema_type: object, type_name: str) -> bool:
    if isinstance(schema_type, str):
        return schema_type == type_name
    if isinstance(schema_type, list):
        return type_name in schema_type
    return False


def _resolve_ref(ref: str, definitions: dict[str, object]) -> object:
    prefix = "#/definitions/"
    if ref.startswith(prefix):
        return definitions.get(ref[len(prefix):], True)
    return True


def validate_json_schema_value(
    value: object,
    schema: object,
    definitions: dict[str, object],
    path: str = "$",
) -> list[str]:
    if schema is True:
        return []
    if not isinstance(schema, dict):
        return []
    if "$ref" in schema and isinstance(schema["$ref"], str):
        return validate_json_schema_value(value, _resolve_ref(schema["$ref"], definitions), definitions, path)
    if "anyOf" in schema and isinstance(schema["anyOf"], list):
        failures = [validate_json_schema_value(value, s, definitions, path) for s in schema["anyOf"]]
        if any(not f for f in failures):
            return []
        return [f"{path}: did not match anyOf"]
    if "allOf" in schema and isinstance(schema["allOf"], list):
        failures: list[str] = []
        for subschema in schema["allOf"]:
            failures.extend(validate_json_schema_value(value, subschema, definitions, path))
        return failures
    if "oneOf" in schema and isinstance(schema["oneOf"], list):
        failures = [validate_json_schema_value(value, s, definitions, path) for s in schema["oneOf"]]
        if any(not f for f in failures):
            return []
        return [f"{path}: did not match oneOf"]
    if "enum" in schema and isinstance(schema["enum"], list):
        if value not in schema["enum"]:
            return [f"{path}: {value!r} not in enum {schema['enum']}"]
        return []
    schema_type = schema.get("type")
    if value is None:
        if schema_type is None or _schema_type_allows(schema_type, "null"):
            return []
        return [f"{path}: null is not allowed"]
    if isinstance(value, bool):
        actual_type = "boolean"
    elif isinstance(value, int) and not isinstance(value, bool):
        actual_type = "integer"
    elif isinstance(value, float):
        actual_type = "number"
    elif isinstance(value, str):
        actual_type = "string"
    elif isinstance(value, list):
        actual_type = "array"
    elif isinstance(value, dict):
        actual_type = "object"
    else:
        return [f"{path}: unsupported value type {type(value).__name__}"]
    if schema_type is not None:
        allowed = _schema_type_allows(schema_type, actual_type)
        if actual_type == "integer" and _schema_type_allows(schema_type, "number"):
            allowed = True
        if not allowed:
            return [f"{path}: expected {schema_type}, got {actual_type}"]
    failures: list[str] = []
    if isinstance(value, dict):
        required = schema.get("required") or []
        for key in required:
            if isinstance(key, str) and key not in value:
                failures.append(f"{path}.{key}: missing required key")
        props = schema.get("properties")
        if isinstance(props, dict):
            for key, subvalue in value.items():
                if key in props:
                    failures.extend(validate_json_schema_value(subvalue, props[key], definitions, f"{path}.{key}"))
    if isinstance(value, list):
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, item in enumerate(value[:3]):
                failures.extend(validate_json_schema_value(item, item_schema, definitions, f"{path}[{index}]"))
    return failures


def _sample_thread() -> dict[str, object]:
    return {
        "id": "thr_schema_parity",
        "sessionId": "thr_schema_parity",
        "preview": "",
        "modelProvider": "openai",
        "cliVersion": "CodexKit/0.1",
        "cwd": "/tmp/codexkit-schema",
        "createdAt": 1,
        "updatedAt": 1,
        "ephemeral": False,
        "source": "appServer",
        "status": {"type": "idle"},
        "turns": [],
    }


def _sample_turn() -> dict[str, object]:
    return {"id": "turn_schema_parity", "items": [], "status": "inProgress"}


def _thread_session_response() -> dict[str, object]:
    return {
        "approvalPolicy": "never",
        "approvalsReviewer": "user",
        "cwd": "/tmp/codexkit-schema",
        "model": "gpt-5.1-codex",
        "modelProvider": "openai",
        "sandbox": {"type": "dangerFullAccess"},
        "instructionSources": [],
        "thread": _sample_thread(),
    }


def concrete_response_fixtures() -> dict[str, object]:
    thread = {"thread": _sample_thread()}
    empty: dict[str, object] = {}
    return {
        "initialize": {
            "userAgent": "CodexKit/0.1 (schema)",
            "codexHome": "/tmp/codexkit-schema-home",
            "platformFamily": "Darwin",
            "platformOs": "macos",
        },
        "thread/start": _thread_session_response(),
        "thread/resume": _thread_session_response(),
        "thread/fork": _thread_session_response(),
        "thread/archive": empty,
        "thread/unarchive": thread,
        "thread/unsubscribe": {"status": "unsubscribed"},
        "thread/name/set": empty,
        "thread/list": {"data": [], "nextCursor": None, "backwardsCursor": None},
        "thread/loaded/list": {"data": [], "nextCursor": None},
        "thread/read": thread,
        "thread/turns/list": {"data": [], "nextCursor": None, "backwardsCursor": None},
        "thread/turns/items/list": {"data": [], "nextCursor": None, "backwardsCursor": None},
        "thread/inject_items": empty,
        "thread/rollback": {"thread": {**_sample_thread(), "turns": []}},
        "thread/compact/start": empty,
        "thread/shellCommand": empty,
        "thread/goal/set": {"goal": {
            "threadId": "thr_schema_parity",
            "objective": "schema parity",
            "status": "active",
            "tokenBudget": None,
            "tokensUsed": 0,
            "timeUsedSeconds": 0,
            "createdAt": 1,
            "updatedAt": 1,
        }},
        "thread/goal/get": {"goal": None},
        "thread/goal/clear": {"cleared": True},
        "thread/memoryMode/set": empty,
        "memory/reset": empty,
        "turn/start": {"turn": _sample_turn()},
        "turn/interrupt": empty,
        "turn/steer": {"turnId": "turn_schema_parity"},
        "review/start": {"reviewThreadId": "thr_schema_parity", "turn": _sample_turn()},
        "model/list": {"data": [], "nextCursor": None},
        "modelProvider/capabilities/read": {
            "namespaceTools": True,
            "imageGeneration": False,
            "webSearch": True,
        },
        "config/read": {"config": {}, "origins": {}, "layers": None},
        "account/read": {"account": None, "requiresOpenaiAuth": True},
        "account/rateLimits/read": {
            "rateLimits": {
                "limitId": None,
                "limitName": None,
                "primary": None,
                "secondary": None,
                "credits": None,
                "planType": None,
                "rateLimitReachedType": None,
            },
            "rateLimitsByLimitId": None,
        },
        "skills/list": {"data": []},
        "skills/extraRoots/set": empty,
        "thread/delete": empty,
        "permissionProfile/list": {"data": [], "nextCursor": None},
        "account/usage/read": {
            "summary": {
                "currentStreakDays": None,
                "lifetimeTokens": None,
                "longestRunningTurnSec": None,
                "longestStreakDays": None,
                "peakDailyTokens": None,
            },
            "dailyUsageBuckets": None,
        },
        "mcpServerStatus/list": {"data": [], "nextCursor": None},
        "collaborationMode/list": {"data": []},
        "app/list": {"data": [], "nextCursor": None},
        "experimentalFeature/list": {"data": [], "nextCursor": None},
        "configRequirements/read": {"requirements": None},
    }


def concrete_response_report(repo_root: Path, codex_tree: Path) -> dict[str, object]:
    typed_source = (repo_root / "Sources/ProtocolModel/ClientRequest.swift").read_text()
    match = re.search(r"typedMethods:\s*Set<String>\s*=\s*\[(.*?)\]", typed_source, re.S)
    typed_methods = set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()
    response_types = client_response_types(codex_tree)
    fixtures = concrete_response_fixtures()
    checked: dict[str, object] = {}
    failures: list[str] = []
    skipped: dict[str, str] = {}
    for method in sorted(typed_methods):
        response = response_types.get(method)
        if response is None:
            # Port-only typed method (e.g. wiki/*, channels/*, cron/*): there is
            # no upstream response schema to conform to, so a concrete-response
            # fixture would be meaningless (and could never match). This report
            # validates ported UPSTREAM methods only; port extensions are out of
            # scope here and are recorded as skipped rather than failed.
            skipped[method] = "no upstream response type (port-only method)"
            continue
        if method not in fixtures:
            failures.append(f"{method}: missing concrete response fixture")
            continue
        alternatives, reason = response_schema_alternatives(codex_tree, response[0], response[1])
        if reason:
            failures.append(f"{method}: {reason}")
            continue
        value = fixtures[method]
        alt_failures: list[list[str]] = []
        accepted = False
        for alternative in alternatives:
            schema_failures = validate_json_schema_value(value, alternative["schema"], alternative["definitions"])
            actual = set(value.keys()) if isinstance(value, dict) else set()
            extra = sorted(actual - alternative["all"])
            if extra:
                schema_failures = schema_failures + [f"$: extra keys {extra}"]
            alt_failures.append(schema_failures)
            if not schema_failures:
                accepted = True
                break
        checked[method] = {
            "responseType": "::".join(p for p in response if p),
            "fixtureKeys": sorted(value.keys()) if isinstance(value, dict) else [],
            "alternatives": alt_failures,
        }
        if not accepted:
            failures.append(f"{method}: concrete response fixture does not match {response}")
    return {
        "checkedCount": len(checked),
        "checked": checked,
        "failures": failures,
        "skippedCount": len(skipped),
        "skipped": skipped,
    }


def generic_response_report(repo_root: Path, codex_tree: Path) -> dict[str, object]:
    response_types = client_response_types(codex_tree)
    explicit_methods = swift_explicit_generic_methods(repo_root)
    swift_values = swift_generic_default_values(repo_root)
    checked: dict[str, object] = {}
    skipped: dict[str, str] = {}
    failures: list[str] = []

    for method in sorted(explicit_methods):
        response = response_types.get(method)
        if response is None:
            skipped[method] = "missing response type mapping"
            continue
        actual_value = swift_values.get(method)
        if actual_value is None or not isinstance(actual_value, dict):
            failures.append(f"{method}: no parseable GenericResponses default result")
            continue
        actual = set(actual_value.keys())
        alternatives, reason = response_schema_alternatives(codex_tree, response[0], response[1])
        if reason:
            skipped[method] = reason
            continue

        accepted = False
        details: list[dict[str, list[str]]] = []
        for alternative in alternatives:
            required = alternative["required"]
            all_keys = alternative["all"]
            missing = sorted(required - actual)
            extra = sorted(actual - all_keys)
            schema_failures = validate_json_schema_value(
                actual_value,
                alternative["schema"],
                alternative["definitions"],
            )
            details.append({
                "missingRequired": missing,
                "extra": extra,
                "schemaFailures": schema_failures,
            })
            if not missing and not extra and not schema_failures:
                accepted = True
                break
        checked[method] = {
            "responseType": "::".join(p for p in response if p),
            "swiftKeys": sorted(actual),
            "alternatives": details,
        }
        if not accepted:
            failures.append(f"{method}: GenericResponses keys {sorted(actual)} do not match {response}")

    return {
        "checkedCount": len(checked),
        "skippedCount": len(skipped),
        "checked": checked,
        "skipped": skipped,
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("golden")
    g.add_argument("--codex-tree", required=True)
    g.add_argument("--schema-dir", required=True)
    g.add_argument("--golden-dir", required=True)
    g.add_argument("--pin", required=True)
    m = sub.add_parser("method-fields")
    m.add_argument("--schema-dir", required=True)
    s = sub.add_parser("swift-field-report")
    s.add_argument("--repo-root", required=True)
    s.add_argument("--schema-dir", required=True)
    t = sub.add_parser("typescript-manifest")
    t.add_argument("--codex-tree", required=True)
    t.add_argument("--schema-dir", required=True)
    r = sub.add_parser("generic-response-report")
    r.add_argument("--repo-root", required=True)
    r.add_argument("--codex-tree", required=True)
    c = sub.add_parser("concrete-response-report")
    c.add_argument("--repo-root", required=True)
    c.add_argument("--codex-tree", required=True)
    args = parser.parse_args()

    if args.cmd == "golden":
        write_golden(Path(args.codex_tree), Path(args.schema_dir), Path(args.golden_dir), args.pin)
        return 0
    if args.cmd == "method-fields":
        _, params = methods_and_params(Path(args.schema_dir))
        print(json.dumps(params, indent=2, sort_keys=True))
        return 0
    if args.cmd == "swift-field-report":
        _, params = methods_and_params(Path(args.schema_dir))
        report = swift_field_report(Path(args.repo_root), params)
        print(json.dumps(report, indent=2, sort_keys=True))
        if report["failures"]:
            return 1
        return 0
    if args.cmd == "typescript-manifest":
        print(json.dumps(typescript_manifest(Path(args.codex_tree), Path(args.schema_dir)), indent=2, sort_keys=True))
        return 0
    if args.cmd == "generic-response-report":
        report = generic_response_report(Path(args.repo_root), Path(args.codex_tree))
        print(json.dumps(report, indent=2, sort_keys=True))
        if report["failures"]:
            return 1
        return 0
    if args.cmd == "concrete-response-report":
        report = concrete_response_report(Path(args.repo_root), Path(args.codex_tree))
        print(json.dumps(report, indent=2, sort_keys=True))
        if report["failures"]:
            return 1
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
