import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('discovery_runner', SCRIPTS / 'check_research_source_discovery_app.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def valid():
    observation = {'query': 'Swift concurrency documentation', 'provider': 'duckDuckGoHTML',
        'http_status': 200, 'main_load_requests': 1, 'candidate_count': 3, 'distinct_origin_count': 2,
        'html_bytes': 1234, 'dom_sha256': 'a' * 64, 'observed_at': '2026-11-10T18:45:24Z',
        'selected_public_urls': ['https://docs.swift.org/a', 'https://developer.apple.com/b'],
        'selected_dom_indices': [0, 1]}
    return {'status': 'PASS', 'failure': 'none', 'stage': 'late_cancelled_tasks', 'passed': 5,
        'groups': dict.fromkeys(runner.LIVE_GROUPS, 1), 'observations': [observation, copy.deepcopy(observation)],
        'main_load_requests': 2, 'adapters_created': 4, 'seconds': 2.5,
        'query': 'Swift concurrency documentation', 'actual_app_session': True, 'actual_webkit': True,
        'fabricated_dom': False, 'model_requests': 0, 'candidate_body_reads': 0,
        'personal_webkit_store': False, 'native_ios_execution': False, 'retries': 0}


class FixedReportChecks(unittest.TestCase):
    def reject(self, value, success=True):
        with self.assertRaises(runner.CheckFailure):
            runner.parse_live_result(json.dumps(value).encode(), success)

    def test_complete_bounded_report(self):
        value = valid()
        self.assertEqual(runner.parse_live_result(json.dumps(value).encode(), True), value)

    def test_fixed_partial_failure_retained_without_pass(self):
        value = valid()
        value.update(status='FAIL', failure='provider_search_failed', stage='search',
                     passed=3, groups={}, observations=[], main_load_requests=1, adapters_created=1)
        self.assertEqual(runner.parse_live_result(json.dumps(value).encode(), False), value)
        self.reject(value, True)

    def test_duplicate_and_escaped_fields(self):
        raw = json.dumps(valid())
        for duplicate in ['"status":"PASS",', '"sta\\u0074us":"PASS",']:
            with self.assertRaises(runner.CheckFailure):
                runner.parse_live_result(('{' + duplicate + raw[1:]).encode(), True)
        raw = raw.replace('"http_status": 200', '"http_status":200,"http_status":200', 1)
        with self.assertRaises(runner.CheckFailure):
            runner.parse_live_result(raw.encode(), True)

    def test_unrecognized_private_fields_never_echoed(self):
        for position in ['outer', 'observation']:
            value = valid()
            target = value if position == 'outer' else value['observations'][0]
            target['raw_private_configuration'] = 'SYNTHETIC_DO_NOT_ECHO'
            try:
                runner.parse_live_result(json.dumps(value).encode(), True)
            except runner.CheckFailure as error:
                self.assertNotIn('SYNTHETIC_DO_NOT_ECHO', str(error))
            else:
                self.fail('Unknown fields must be rejected')

    def test_numeric_boolean_and_traffic_claims(self):
        for key, bad in [('passed', True), ('main_load_requests', 3), ('adapters_created', 3),
                         ('seconds', float('inf')), ('seconds', float('nan')), ('seconds', -1),
                         ('retries', 1), ('candidate_body_reads', 1), ('model_requests', 1)]:
            value = valid(); value[key] = bad; self.reject(value)

    def test_missing_groups_and_inconsistent_assertion_total(self):
        value = valid(); value['groups'].pop('lateCancelledTasks'); self.reject(value)
        value = valid(); value['passed'] += 1; self.reject(value)
        value = valid(); value['groups']['invented'] = 2; self.reject(value)

    def test_source_evidence_fields_required(self):
        for key, bad in [('dom_sha256', 'not-a-digest'), ('http_status', 302),
                         ('main_load_requests', 2), ('candidate_count', 31),
                         ('distinct_origin_count', 1), ('html_bytes', 1024 * 1024 + 1),
                         ('selected_dom_indices', [1, 1]), ('observed_at', 'arbitrary output')]:
            value = valid(); value['observations'][0][key] = bad; self.reject(value)

    def test_public_url_output_is_bounded_and_credentials_excluded(self):
        for address in ['file:///tmp/a', 'http://example.com/a', 'https://name:secret@example.com/a',
                        'https://example.com/?token=synthetic', 'https://example.com/a#secret',
                        'https://example.com/' + 'a' * 2048, 'https://example.com/a\nsecret',
                        'https://docs.swift.org/same-origin']:
            value = valid(); value['observations'][0]['selected_public_urls'][1] = address; self.reject(value)

    def test_failure_is_fixed_enum_and_exit_code_bound(self):
        value = valid(); self.reject(value, False)
        value.update(status='FAIL', failure='SYNTHETIC_PRIVATE_ERROR'); self.reject(value, False)

    def test_no_fabricated_dom_or_native_ui_claim(self):
        for key in ['fabricated_dom', 'native_ios_execution', 'personal_webkit_store']:
            value = valid(); value[key] = True; self.reject(value)
        value = valid(); value['actual_app_session'] = False; self.reject(value)

    def test_malformed_or_oversized_output(self):
        for raw in [b'not json', b'{', b'[]', b' ' * (64 * 1024 + 1)]:
            with self.assertRaises(runner.CheckFailure):
                runner.parse_live_result(raw, True)


if __name__ == '__main__':
    unittest.main()
