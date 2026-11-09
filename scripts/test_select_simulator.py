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


if __name__ == "__main__":
    unittest.main()
