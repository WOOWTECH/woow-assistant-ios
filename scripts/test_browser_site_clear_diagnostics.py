import json
import unittest
from copy_browser_site_clear_diagnostics import checked


class SiteClearDiagnosticsTests(unittest.TestCase):
    def test_complete_current_operation_trace_is_retained(self):
        events = [
            {"phase": "begin", "records": "1", "sessions": "2", "persistent": "1", "elapsedMs": "0"},
            {"phase": "pageBegin", "index": "0", "elapsedMs": "1"},
            {"phase": "pageFinished", "index": "0", "stopped": "1", "elapsedMs": "12"},
            {"phase": "pagesDiscarded", "ready": "1", "elapsedMs": "29"},
            {"phase": "recordsSelected", "records": "1", "types": "2", "elapsedMs": "30"},
            {"phase": "removeRequested", "elapsedMs": "31"},
            {"phase": "removeCompleted", "elapsedMs": "35"},
            {"phase": "recordsRefreshed", "allRecords": "1", "selectedRecords": "0", "selectedCookieRecords": "0",
             "selectedMemoryCacheRecords": "0", "selectedDiskCacheRecords": "0", "selectedOtherDataTypes": "0", "elapsedMs": "36"},
            {"phase": "sessionsReplaced", "ready": "1", "elapsedMs": "37"},
        ]
        self.assertEqual(json.loads(checked(json.dumps(events).encode())), events)

    def test_no_op_stays_distinct_from_a_removal_callback(self):
        events = [{"phase": "removeNotNeeded", "elapsedMs": "1"}]
        self.assertEqual(json.loads(checked(json.dumps(events).encode())), events)

    def test_unknown_or_potentially_private_fields_never_leave_runner(self):
        for event in [
            {"phase": "recordsSelected", "records": "1", "types": "1", "elapsedMs": "0", "host": "example.invalid"},
            {"phase": "recordsSelected", "records": "cookie-value", "types": "1", "elapsedMs": "0"},
            {"phase": "pagesDiscarded", "ready": True, "elapsedMs": "0"},
            {"phase": "newUnreviewedPhase", "elapsedMs": "0"},
            {"phase": "removeCompleted", "elapsedMs": "-1"},
        ]:
            with self.subTest(event=event), self.assertRaises(ValueError):
                checked(json.dumps([event]).encode())

    def test_size_and_event_bounds_remain_enforced(self):
        with self.assertRaises(ValueError):
            checked(b' ' * 16385)
        with self.assertRaises(ValueError):
            checked(json.dumps([{"phase": "removeCompleted", "elapsedMs": "0"}] * 65).encode())


if __name__ == '__main__':
    unittest.main()
