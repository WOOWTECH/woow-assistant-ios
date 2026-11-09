import tempfile
import unittest
from pathlib import Path
from prepare_simulator_webkit import prepare


class SimulatorWebKitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.runtime = root / "iOS 18.5.simruntime"
        self.library = self.runtime / "Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift/libswiftWebKit.dylib"
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"fixture-system-overlay")
        self.products = root / "products"
        self.products.mkdir()
        self.payload = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                                      "isAvailable": True, "bundlePath": str(self.runtime)}]}

    def test_links_selected_runtime_without_copying_into_app(self):
        self.assertTrue(prepare(self.payload, "iOS-18-5", self.products))
        link = self.products / self.library.name
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), self.library.resolve())
        self.assertTrue(prepare(self.payload, "iOS-18-5", self.products))
        self.assertEqual(list(self.products.iterdir()), [link])

    def test_other_runtime_is_untouched(self):
        self.assertFalse(prepare({}, "iOS-26-2", self.products))
        self.assertEqual(list(self.products.iterdir()), [])

    def test_missing_overlay_fails_clearly(self):
        self.library.unlink()
        with self.assertRaises(ValueError):
            prepare(self.payload, "iOS-18-5", self.products)

    def test_existing_regular_file_is_preserved(self):
        destination = self.products / self.library.name
        destination.write_bytes(b"existing")
        with self.assertRaises(ValueError):
            prepare(self.payload, "iOS-18-5", self.products)
        self.assertEqual(destination.read_bytes(), b"existing")

    def test_unavailable_or_ambiguous_runtime_is_rejected(self):
        for payload in ({}, {"runtimes": self.payload["runtimes"] * 2}):
            with self.assertRaises(ValueError):
                prepare(payload, "iOS-18-5", self.products)
        self.payload["runtimes"][0]["isAvailable"] = False
        with self.assertRaises(ValueError):
            prepare(self.payload, "iOS-18-5", self.products)
