import json
from pathlib import Path
import subprocess
import sys
import unittest

from select_simulator import select_device


def device(name, udid, available=True):
    return {"name": name, "udid": udid, "isAvailable": available}


class SimulatorSelectionTests(unittest.TestCase):
    def setUp(self):
        self.payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                device("iPhone 16", "ios18"),
                device("iPad Pro", "ipad"),
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                device("iPhone 17", "ios26"),
                device("iPhone 17 Pro", "unavailable", False),
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                device("iPhone 14", "too-old"),
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [
                device("Apple TV", "tv"),
            ],
        }}
        self.matrix_payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                device("iPhone SE (3rd generation)", "compact18"),
                device("iPhone 16 Pro Max", "large18"),
                device("iPhone 16 Pro", "pro18"),
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                device("iPhone 16 Pro Max", "large26"),
                device("iPhone 17 Pro Max", "other26"),
            ],
        }}

    def test_pinned_runtime_ignores_newer_sdk(self):
        self.assertEqual(select_device(self.payload, "iOS-18-5"), "ios18")

    def test_local_default_uses_newest_available_iphone(self):
        self.assertEqual(select_device(self.payload), "ios26")

    def test_missing_pinned_runtime_is_error_not_silent_fallback(self):
        with self.assertRaises(ValueError):
            select_device(self.payload, "iOS-17-5")

    def test_empty_payload_is_error(self):
        with self.assertRaises(ValueError):
            select_device({})

    def test_pre_ios17_devices_are_rejected(self):
        with self.assertRaises(ValueError):
            select_device(self.payload, "iOS-16-4")

    def test_ipad_only_is_error(self):
        with self.assertRaises(ValueError):
            select_device({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                device("iPad Pro", "ipad"),
            ]}})

    def test_exact_compact_and_large_device_names_in_pinned_runtime(self):
        for name, expected in [
            ("iPhone SE (3rd generation)", "compact18"),
            ("iPhone 16 Pro Max", "large18"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(
                    select_device(self.matrix_payload, "iOS-18-5", name), expected
                )

    def test_name_only_uses_newest_runtime_with_that_device(self):
        for name, expected in [
            ("iPhone SE (3rd generation)", "compact18"),
            ("iPhone 16 Pro Max", "large26"),
        ]:
            with self.subTest(name=name):
                self.assertEqual(
                    select_device(self.matrix_payload, device_name=name), expected
                )

    def test_name_must_match_exactly_without_case_or_whitespace_normalization(self):
        for name in [
            "iPhone SE", "iPhone SE 3rd generation", "iPhone SE (2nd generation)",
            "iPhone 16 Pro Ma", "iPhone 16 Pro Max Plus", "iPhone 16 Pro Max ",
            " iPhone 16 Pro Max", "iphone 16 pro max", "iPhone 15", "",
        ]:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    select_device(self.matrix_payload, device_name=name)

    def test_unavailable_requested_device_does_not_select_another_name(self):
        for requested, alternative in [
            ("iPhone SE (3rd generation)", "iPhone 16 Pro Max"),
            ("iPhone 16 Pro Max", "iPhone SE (3rd generation)"),
        ]:
            with self.subTest(name=requested):
                payload = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    device(requested, "unavailable", False),
                    device(alternative, "available"),
                ]}}
                with self.assertRaises(ValueError):
                    select_device(payload, "iOS-18-5", requested)

    def test_requested_device_in_another_runtime_is_not_a_fallback(self):
        with self.assertRaises(ValueError):
            select_device(self.matrix_payload, "iOS-26-2", "iPhone SE (3rd generation)")

    def test_unavailable_pinned_device_does_not_select_newer_available_copy(self):
        self.matrix_payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-18-5"][1]["isAvailable"] = False
        with self.assertRaises(ValueError):
            select_device(self.matrix_payload, "iOS-18-5", "iPhone 16 Pro Max")

    def test_runtime_filter_is_exact_and_never_falls_back(self):
        for runtime in ["iOS-18", "iOS-18-50", "iOS-18-5-0", "iOS-17-5", "ios-18-5", ""]:
            with self.subTest(runtime=runtime):
                with self.assertRaises(ValueError):
                    select_device(self.matrix_payload, runtime, "iPhone 16 Pro Max")

    def test_ios17_minimum_and_patch_runtime(self):
        name = "iPhone SE (3rd generation)"
        payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-16-9-9": [device(name, "old")],
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [device(name, "minimum")],
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0-1": [device(name, "patch")],
        }}
        for runtime, expected in [(None, "patch"), ("iOS-17-0", "minimum"), ("iOS-17-0-1", "patch")]:
            with self.subTest(runtime=runtime):
                self.assertEqual(select_device(payload, runtime, name), expected)
        with self.assertRaises(ValueError):
            select_device(payload, "iOS-16-9-9", name)

    def test_runtime_versions_sort_numerically(self):
        name = "iPhone 16 Pro Max"
        payload = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-9": [device(name, "minor9")],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-10-2": [device(name, "patch2")],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-10-10": [device(name, "patch10")],
        }}
        self.assertEqual(select_device(payload, device_name=name), "patch10")

    def test_exact_name_does_not_bypass_iphone_or_runtime_eligibility(self):
        for name, runtime in [
            ("iPad Pro", "iOS-18-5"),
            ("iPhone 16 Pro Max", "tvOS-26-2"),
            ("iPhone SE (3rd generation)", "iOS-16-4"),
            ("iPhone 16 Pro Max", "iOS-18-5-beta"),
        ]:
            with self.subTest(name=name, runtime=runtime):
                payload = {"devices": {"com.apple.CoreSimulator.SimRuntime." + runtime: [
                    device(name, "ineligible"),
                ]}}
                with self.assertRaises(ValueError):
                    select_device(payload, device_name=name)

    def test_no_name_filter_preserves_existing_name_and_udid_tiebreaks(self):
        payload = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
            device("iPhone 16", "base"),
            device("iPhone 16 Pro Max", "large-a"),
            device("iPhone 16 Pro Max", "large-z"),
            device("iPhone SE (3rd generation)", "compact"),
        ]}}
        self.assertEqual(select_device(payload, "iOS-18-5"), "compact")
        self.assertEqual(select_device(payload, "iOS-18-5", None), "compact")
        self.assertEqual(select_device(payload, "iOS-18-5", "iPhone 16 Pro Max"), "large-z")

    def test_failure_names_both_requested_filters(self):
        with self.assertRaises(ValueError) as caught:
            select_device(self.matrix_payload, "iOS-17-5", "iPhone SE (3rd generation)")
        self.assertIn("iOS-17-5", str(caught.exception))
        self.assertIn("iPhone SE (3rd generation)", str(caught.exception))

    def test_cli_selects_both_matrix_devices(self):
        for name, expected in [
            ("iPhone SE (3rd generation)", "compact18"),
            ("iPhone 16 Pro Max", "large18"),
        ]:
            with self.subTest(name=name):
                result = self.run_cli("--runtime", "iOS-18-5", "--device", name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected + "\n")
                self.assertEqual(result.stderr, "")

    def test_cli_unavailable_filter_exits_nonzero_without_destination(self):
        for arguments in [
            ("--runtime", "iOS-26-2", "--device", "iPhone SE (3rd generation)"),
            ("--runtime", "iOS-17-5", "--device", "iPhone 16 Pro Max"),
            ("--device", "iPhone 15"),
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_cli(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("No available iPhone", result.stderr)

    def test_cli_without_filters_preserves_default(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "other26\n")
        self.assertEqual(result.stderr, "")

    def run_cli(self, *arguments):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("select_simulator.py")), *arguments],
            input=json.dumps(self.matrix_payload), text=True, capture_output=True, check=False,
        )


if __name__ == "__main__":
    unittest.main()
