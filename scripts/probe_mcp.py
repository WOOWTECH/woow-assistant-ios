"""Read-only MCP discovery probe; webhook endpoint is a secret, never printed.

No tool is called by default. Server descriptions are data, never instructions.
"""
import argparse
import getpass
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class RejectRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class MCPProbe:
    def __init__(self, endpoint):
        parsed = urllib.parse.urlsplit(endpoint)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            raise ValueError("invalid_endpoint")
        self.endpoint = endpoint
        self.session = None
        self.protocol = "2025-03-26"
        self.counter = 0
        self.opener = urllib.request.build_opener(RejectRedirect())

    def request(self, method, params=None, notification=False):
        started = time.monotonic()
        self.counter += 1
        payload = {"jsonrpc": "2.0", "method": method}
        if not notification:
            payload["id"] = self.counter
        if params is not None:
            payload["params"] = params
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "User-Agent": "WoowAssistant-MCPTest/0.1", "MCP-Protocol-Version": self.protocol}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(self.endpoint, data=json.dumps(payload).encode(), headers=headers, method="POST")
        with self.opener.open(request, timeout=30) as response:
            self.session = response.headers.get("Mcp-Session-Id", self.session)
            if notification and response.status in (202, 204):
                return {"accepted": True}
            if "text/event-stream" in response.headers.get("Content-Type", ""):
                total = 0
                while total < 4_194_304:
                    if time.monotonic() - started > 60:
                        raise ValueError("request_deadline")
                    line = response.readline(4_194_305)
                    total += len(line)
                    if not line or len(line) > 4_194_304:
                        break
                    if line.startswith(b"data:"):
                        message = json.loads(line[5:].strip())
                        if message.get("id") == payload.get("id"):
                            return message
                raise ValueError("missing_rpc_response")
            data = response.read(2_000_001)
            if len(data) > 2_000_000:
                raise ValueError("response_too_large")
            if not data and notification:
                return {"accepted": True}
            message = json.loads(data)
            if not notification and message.get("id") != payload["id"]:
                raise ValueError("response_id_mismatch")
            return message

    def collect(self, method, field):
        rows, cursor, seen = [], None, set()
        for _ in range(20):
            message = self.request(method, {"cursor": cursor} if cursor else {})
            if "error" in message:
                return {"rpc_error": message["error"].get("code")}
            result = message["result"]
            rows.extend(result.get(field, []))
            cursor = result.get("nextCursor")
            if not cursor:
                return rows
            if cursor in seen:
                raise ValueError("repeated_cursor")
            seen.add(cursor)
        raise ValueError("pagination_limit")


def tool_summary(message):
    """Only structural evidence is public: never print household state or text."""
    if "error" in message:
        return {"status": "rpc_error", "code": message["error"].get("code")}
    result = message.get("result", {})
    return {"status": "tool_error" if result.get("isError", False) else "passed",
            "content_blocks": len(result.get("content", [])),
            "structured_content": "structuredContent" in result}


def structured_values(message):
    result = message.get("result", {})
    if "structuredContent" in result:
        yield result["structuredContent"]
    for content in result.get("content", []):
        if content.get("type") == "text":
            try:
                yield json.loads(content.get("text", ""))
            except (ValueError, TypeError):
                pass


def entity_ids(value):
    if isinstance(value, dict):
        entity = value.get("entity_id")
        if isinstance(entity, str) and "." in entity:
            yield entity
        for child in value.values():
            yield from entity_ids(child)
    elif isinstance(value, list):
        for child in value:
            yield from entity_ids(child)


def read_only_checks(client, tools, resources):
    """Explicit audited test cases, not a server annotation-driven allowlist."""
    available = {tool.get("name") for tool in tools}
    cases = [
        ("ha_get_overview", {}),
        ("ha_list_floors_areas", {}),
        ("ha_list_services", {"limit": 3}),
        ("ha_search", {"query": "sensor", "limit": 3, "include_config": False}),
        ("ha_get_skill_guide", {}),
        ("ha_config_get_dashboard", {"list_only": True, "include_config": False, "include_screenshot": False}),
        ("ha_eval_template", {"template": "{{ 1 + 1 }}"}),
    ]
    failures, discovered = 0, None
    for name, arguments in cases:
        if name not in available:
            print(json.dumps({"tool": name, "status": "not_advertised"}))
            continue
        reply = client.request("tools/call", {"name": name, "arguments": arguments})
        summary = tool_summary(reply)
        failures += summary["status"] != "passed"
        if name in ("ha_search", "ha_get_overview"):
            for value in structured_values(reply):
                discovered = discovered or next(entity_ids(value), None)
        print(json.dumps({"tool": name, **summary}))
    if "ha_get_state" in available and discovered:
        reply = client.request("tools/call", {"name": "ha_get_state", "arguments": {"entity_id": discovered}})
        summary = tool_summary(reply)
        failures += summary["status"] != "passed"
        print(json.dumps({"tool": "ha_get_state", "target": "discovered_entity_redacted", **summary}))
    else:
        print(json.dumps({"tool": "ha_get_state", "status": "no_target_discovered"}))
    # Read-only invalid arguments should be a tool or RPC error, never a transport crash.
    if "ha_get_state" in available:
        invalid = client.request("tools/call", {"name": "ha_get_state", "arguments": {"entity_id": "sensor.woow_validation_nonexistent"}})
        summary = tool_summary(invalid)
        print(json.dumps({"negative_test": "missing_entity", **summary}))
    unknown = client.request("tools/call", {"name": "woow_validation_nonexistent_tool", "arguments": {}})
    summary = tool_summary(unknown)
    failures += summary["status"] == "passed"
    print(json.dumps({"negative_test": "unknown_tool", **summary}))
    # Only read documentation/guide resources, not arbitrary cameras or private files.
    guide = next((resource for resource in resources
                  if any(term in (resource.get("name", "") + " " + resource.get("uri", "")).lower()
                         for term in ("guide", "best_practice", "best-practice", "skill"))), None)
    if guide:
        reply = client.request("resources/read", {"uri": guide["uri"]})
        contents = reply.get("result", {}).get("contents", [])
        passed = "error" not in reply and bool(contents)
        failures += not passed
        print(json.dumps({"resource_read": "documentation_only", "status": "passed" if passed else "failed", "content_blocks": len(contents)}))
    else:
        print(json.dumps({"resource_read": "skipped_no_documentation_resource"}))
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--read-only", action="store_true", help="Run explicitly reviewed non-mutating HA calls")
    parser.add_argument("--schemas", action="store_true", help="Print schemas, never state or credential values")
    options = parser.parse_args()
    endpoint = os.environ.get("WOOW_HA_MCP_TEST_URL") or getpass.getpass("HA MCP webhook URL (hidden): ")
    client = MCPProbe(endpoint)
    initialized = client.request("initialize", {
        "protocolVersion": client.protocol, "capabilities": {},
        "clientInfo": {"name": "woow-ios-validation", "version": "0.1.0"}
    })
    if "error" in initialized:
        print(json.dumps({"initialize_rpc_error": initialized["error"].get("code")}))
        return 1
    result = initialized["result"]
    protocol = result["protocolVersion"]
    if protocol not in ("2024-11-05", "2025-03-26", "2025-06-18"):
        print(json.dumps({"unsupported_protocol": protocol}))
        return 1
    client.protocol = protocol
    capabilities = result.get("capabilities", {})
    print(json.dumps({"initialize": "passed", "protocol": protocol, "capabilities": sorted(capabilities), "uses_session": bool(client.session)}))
    ready = client.request("notifications/initialized", notification=True)
    print(json.dumps({"initialized_notification": ready.get("accepted", "responded")}))
    catalogs = {}
    for capability, method, field in [("tools", "tools/list", "tools"), ("resources", "resources/list", "resources"),
                                      ("resources", "resources/templates/list", "resourceTemplates"), ("prompts", "prompts/list", "prompts")]:
        if capability not in capabilities:
            print(json.dumps({"method": method, "status": "not_advertised"}))
            continue
        print(json.dumps({"method": method, "status": "requesting"}))
        rows = client.collect(method, field)
        if isinstance(rows, dict):
            print(json.dumps({"method": method, **rows}))
            continue
        print(json.dumps({"method": method, "count": len(rows)}))
        catalogs[field] = rows
        if field == "tools" and options.schemas:
            for tool in rows:
                # Schemas are needed to choose genuinely read-only follow-up tests.
                schema = tool.get("inputSchema") or {}
                properties = {name: {"type": value.get("type"), "enum_count": len(value.get("enum", []))}
                              for name, value in schema.get("properties", {}).items() if isinstance(value, dict)}
                print(json.dumps({"tool": tool.get("name"), "required": schema.get("required", []), "properties": properties, "annotations": tool.get("annotations")}))
    ping = client.request("ping")
    print(json.dumps({"ping": "passed" if "result" in ping else "rpc_error", "code": ping.get("error", {}).get("code")}))
    unknown = client.request("woow/unknownValidationMethod")
    print(json.dumps({"unknown_method_error": unknown.get("error", {}).get("code")}))
    failures = read_only_checks(client, catalogs.get("tools", []), catalogs.get("resources", [])) if options.read_only else 0
    print(json.dumps({"read_only_failure_count": failures, "mutation_calls": 0}))
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as error:
        print(json.dumps({"error": "http_error", "status": error.code}))
        sys.exit(1)
    except Exception as error:
        code = str(error) if str(error) in ("invalid_endpoint", "missing_rpc_response", "response_too_large", "response_id_mismatch", "repeated_cursor", "pagination_limit") else "redacted"
        print(json.dumps({"error": type(error).__name__, "code": code}))
        sys.exit(1)
