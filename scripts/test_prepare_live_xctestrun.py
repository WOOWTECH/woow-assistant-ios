import unittest

from prepare_live_xctestrun import configure


class LiveRunnerConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.env = {"WOOW_MODEL_TEST_BASE_URL": "https://model.invalid/v1",
                    "WOOW_MODEL_TEST_MODEL": "fixture", "WOOW_MODEL_TEST_API_KEY": "fixture-not-a-key"}

    def test_v2_injects_only_ui_runner(self):
        unit = {"BlueprintName": "AssistantModelsTests"}
        ui = {"BlueprintName": "WoowAssistantUITests", "EnvironmentVariables": {"EXISTING": "keep"}}
        payload = {"TestConfigurations": [{"TestTargets": [unit, ui]}]}
        configure(payload, self.env)
        self.assertNotIn("EnvironmentVariables", unit)
        self.assertEqual(ui["EnvironmentVariables"]["WOOW_LIVE_API_KEY"], "fixture-not-a-key")
        self.assertEqual(ui["EnvironmentVariables"]["EXISTING"], "keep")

    def test_legacy_format(self):
        payload = {"WoowAssistantUITests": {}}
        configure(payload, self.env)
        self.assertEqual(len(payload["WoowAssistantUITests"]["EnvironmentVariables"]), 3)

    def test_clear_removes_only_live_values(self):
        payload = {"WoowAssistantUITests": {"EnvironmentVariables": {"EXISTING": "keep"}}}
        configure(payload, self.env)
        configure(payload, {}, clear=True)
        self.assertEqual(payload["WoowAssistantUITests"]["EnvironmentVariables"], {"EXISTING": "keep"})

    def test_missing_runner_rejected(self):
        with self.assertRaises(ValueError):
            configure({}, self.env)

    def test_mcp_configuration_never_injects_model_key(self):
        payload = {"WoowAssistantUITests": {}}
        configure(payload, {"WOOW_HA_MCP_TEST_URL": "https://mcp.example.invalid/private"}, service="mcp")
        self.assertEqual(payload["WoowAssistantUITests"]["EnvironmentVariables"],
                         {"WOOW_LIVE_MCP_URL": "https://mcp.example.invalid/private"})
        configure(payload, {}, clear=True, service="mcp")
        self.assertEqual(payload["WoowAssistantUITests"]["EnvironmentVariables"], {})

    def test_unknown_service_rejected(self):
        with self.assertRaises(ValueError):
            configure({}, {}, service="unknown")

    def test_combined_services_clear_independently(self):
        payload = {"WoowAssistantUITests": {}}
        configure(payload, self.env)
        configure(payload, {"WOOW_HA_MCP_TEST_URL": "https://mcp.example.invalid/private"}, service="mcp")
        variables = payload["WoowAssistantUITests"]["EnvironmentVariables"]
        self.assertEqual(len(variables), 4)
        configure(payload, {}, clear=True, service="mcp")
        self.assertNotIn("WOOW_LIVE_MCP_URL", variables)
        self.assertEqual(len(variables), 3)
        configure(payload, {}, clear=True)
        self.assertEqual(variables, {})

    def test_duplicate_runner_rejected(self):
        with self.assertRaises(ValueError):
            configure({"TestConfigurations": [{"TestTargets": [
                {"BlueprintName": "WoowAssistantUITests"}, {"BlueprintName": "WoowAssistantUITests"}]}]}, self.env)

    def test_missing_key_is_rejected_before_changes(self):
        payload = {"WoowAssistantUITests": {}}
        with self.assertRaises(ValueError):
            configure(payload, {})
        self.assertEqual(payload, {"WoowAssistantUITests": {}})
