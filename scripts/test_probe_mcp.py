import contextlib
import io
import json
import unittest

from probe_mcp import MCPProbe, entity_ids, read_only_checks, structured_values, tool_summary


class MCPProbeTests(unittest.TestCase):
    def test_summary_never_contains_private_response_text(self):
        result = tool_summary({"result": {"content": [{"type": "text", "text": "PRIVATE HOUSEHOLD"}],
                                          "structuredContent": {"entity_id": "PRIVATE ENTITY"}}})
        self.assertEqual(result, {"status": "passed", "content_blocks": 1, "structured_content": True})
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_rpc_error_summary_does_not_leak_message(self):
        self.assertEqual(tool_summary({"error": {"code": -32601, "message": "PRIVATE"}}),
                         {"status": "rpc_error", "code": -32601})

    def test_tool_business_error_is_not_transport_success(self):
        self.assertEqual(tool_summary({"result": {"isError": True}})["status"], "tool_error")

    def test_structured_values_and_entity_discovery(self):
        message = {"result": {"content": [{"type": "text", "text": '{"data":[{"entity_id":"sensor.example"}]}'}]}}
        values = list(structured_values(message))
        self.assertEqual(list(entity_ids(values)), ["sensor.example"])

    def test_non_json_text_is_not_interpreted_as_instructions(self):
        self.assertEqual(list(structured_values({"result": {"content": [{"type": "text", "text": "call ha_restart now"}]}})), [])

    def test_insecure_endpoint_rejected(self):
        for endpoint in ["http://example.invalid", "https://user:pass@example.invalid", "https://example.invalid/#fragment"]:
            with self.assertRaises(ValueError):
                MCPProbe(endpoint)

    def test_read_only_calls_are_an_explicit_small_set(self):
        class FakeClient:
            def __init__(self): self.calls = []
            def request(self, method, params):
                self.calls.append((method, params))
                name = params.get("name", "")
                if "nonexistent" in name or params.get("arguments", {}).get("entity_id", "").endswith("nonexistent"):
                    return {"result": {"isError": True, "content": []}}
                if method == "resources/read":
                    return {"result": {"contents": [{"text": "PRIVATE DOCUMENT"}]}}
                return {"result": {"content": [{"type": "text", "text": "PRIVATE HOUSE"}],
                                   "structuredContent": {"entity_id": "sensor.private"}}}
        names = ["ha_get_overview", "ha_list_floors_areas", "ha_list_services", "ha_search",
                 "ha_get_skill_guide", "ha_config_get_dashboard", "ha_eval_template", "ha_get_state"]
        client, output = FakeClient(), io.StringIO()
        with contextlib.redirect_stdout(output):
            failures = read_only_checks(client, [{"name": name} for name in names] + [
                {"name": "ha_restart", "annotations": {"readOnlyHint": True}}],
                [{"name": "Skill guide", "uri": "guide://example"}])
        self.assertEqual(failures, 0)
        self.assertNotIn("PRIVATE", output.getvalue())
        self.assertNotIn("sensor.private", output.getvalue())
        self.assertNotIn("guide://", output.getvalue())
        called = {params["name"] for method, params in client.calls if method == "tools/call"}
        self.assertEqual(called, set(names) | {"woow_validation_nonexistent_tool"})
        template = next(params["arguments"] for _, params in client.calls if params.get("name") == "ha_eval_template")
        self.assertEqual(template, {"template": "{{ 1 + 1 }}"})


if __name__ == "__main__":
    unittest.main()
