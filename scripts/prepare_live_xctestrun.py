"""Inject live credentials into a private, ephemeral XCTest runner configuration.

Never upload the resulting .xctestrun, live xcresult, screenshots or crash logs.
No credential or endpoint is printed. --clear removes the injected variables.
"""
import argparse
import os
import pathlib
import plistlib
import sys

MAPPING = {
    "WOOW_MODEL_TEST_BASE_URL": "WOOW_LIVE_BASE_URL",
    "WOOW_MODEL_TEST_MODEL": "WOOW_LIVE_MODEL",
    "WOOW_MODEL_TEST_API_KEY": "WOOW_LIVE_API_KEY",
}
MCP_MAPPING = {"WOOW_HA_MCP_TEST_URL": "WOOW_LIVE_MCP_URL"}


def configure(payload, environment, clear=False, service="model"):
    if service not in ("model", "mcp"):
        raise ValueError("Unsupported live service")
    mapping = MAPPING if service == "model" else MCP_MAPPING
    targets = []
    if "TestConfigurations" in payload:
        for configuration in payload["TestConfigurations"]:
            for target in configuration.get("TestTargets", []):
                if target.get("BlueprintName") == "WoowAssistantUITests":
                    targets.append(target)
    else:
        target = payload.get("WoowAssistantUITests")
        if isinstance(target, dict):
            targets.append(target)
    if len(targets) != 1:
        raise ValueError("Expected exactly one WoowAssistantUITests runner")
    if not clear and any(not environment.get(source) for source in mapping):
        raise ValueError("Missing live test configuration")
    variables = targets[0].setdefault("EnvironmentVariables", {})
    for source, destination in mapping.items():
        if clear:
            variables.pop(destination, None)
        else:
            variables[destination] = environment[source]
    return payload


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=pathlib.Path)
    parser.add_argument("--clear", action="store_true")
    parser.add_argument("--service", choices=("model", "mcp"), default="model")
    args = parser.parse_args()
    try:
        if args.path.is_symlink() or not args.path.is_file():
            raise ValueError("Expected a generated regular xctestrun file")
        with args.path.open("rb") as source:
            payload = plistlib.load(source)
        updated = configure(payload, os.environ, args.clear, args.service)
        os.chmod(args.path, 0o600)
        with args.path.open("wb") as output:
            plistlib.dump(updated, output)
        print("Live runner configuration cleared" if args.clear else "Live runner configured privately")
    except Exception:
        print("Could not prepare the private live test runner", file=sys.stderr)
        sys.exit(1)
