import copy
import json
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import run_live_chat_streaming as runner


class LiveStreamRunnerTests(unittest.TestCase):
    def test_dotenv_quotes_without_shell_execution(self):
        value = runner.read_dotenv('export LITELLM_BASE_URL="https://synthetic.invalid/v1"\nLITELLM_API_KEY="$(never-execute)"\n')
        self.assertEqual(value['LITELLM_API_KEY'], '$(never-execute)')

    def test_duplicate_and_missing_private_fields_rejected(self):
        for text in ['LITELLM_BASE_URL=https://synthetic.invalid\n',
                     'LITELLM_BASE_URL=https://synthetic.invalid\nLITELLM_API_KEY=x\nLITELLM_API_KEY=y',
                     'LITELLM_BASE_URL=https://synthetic.invalid\nLITELLM_API_KEY=a b']:
            with self.assertRaises(runner.Rejected): runner.read_dotenv(text)

    def test_exact_base_comparison_ignores_only_trailing_slashes(self):
        local = {'LITELLM_BASE_URL': 'https://synthetic.invalid/v1/', 'LITELLM_API_KEY': 'synthetic'}
        self.assertEqual(runner.match_configuration(local, 'https://synthetic.invalid/v1', 'model')[runner.PRIVATE[2]], 'synthetic')
        for base in ['https://other.invalid/v1', 'https://synthetic.invalid/v2', 'http://synthetic.invalid/v1']:
            with self.assertRaises(runner.Rejected): runner.match_configuration(local, base, 'model')

    def valid_result(self):
        return {'schema_version': 1, 'status': 'PASS', 'failure': 'none', 'phase': 'finished',
                'transport_failure': 'none', 'cancel_boundary': 'not_covered_single_sse_delta',
                'partial_observed': True, 'partial_never_saved': True, 'completed_pair_saved': True,
                'encrypted_relaunch_matches': True, 'learning_unchanged': True, 'cancel_covered': False,
                'cancel_no_archive': False, 'cancel_draft_partial_retained': False, 'cancel_no_completion_notification': False,
                'native_ios_ui': False, 'synthetic_prompts_only': True, 'personal_keychain': False,
                'private_defaults_on_disk': False, 'maximum_http_attempts': 4, 'http_stream_attempts': 1,
                'http_stream_completions': 1, 'sse_text_deltas': [1], 'seconds': 1.0}

    def test_uncovered_cancel_is_not_promoted_to_passed_cancel(self):
        value = runner.fixed_result(json.dumps(self.valid_result()))
        self.assertFalse(value['cancel_covered'])
        self.assertEqual(value['cancel_boundary'], 'not_covered_single_sse_delta')

    def test_private_or_unbounded_output_is_never_accepted(self):
        for change in [{'raw_reply': 'private'}, {'failure': 'secret-url'}, {'http_stream_attempts': 5},
                       {'partial_never_saved': False}, {'cancel_covered': True}, {'native_ios_ui': True},
                       {'seconds': float('nan')}, {'sse_text_deltas': ['private']}]:
            value = self.valid_result(); value.update(change)
            with self.assertRaises(runner.Rejected): runner.fixed_result(json.dumps(value))

    def test_duplicate_json_rejected(self):
        with self.assertRaises(runner.Rejected): runner.fixed_result('{"status":"PASS","status":"FAIL"}')

    def test_incomplete_and_missing_checks_fail_before_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = {'status': 'PASS', 'focused': False, 'sources_still_current': True,
                      'release_stream_fixture_absent_from_executable': True, 'checks': [], 'source_sha256': {}}
            for field in [None, 'focused', 'sources_still_current', 'release_stream_fixture_absent_from_executable']:
                value = copy.deepcopy(report)
                if field: value[field] = None
                (root / 'report.json').write_text(json.dumps(value))
                with self.assertRaises(runner.Rejected): runner.validate_snapshot(root, root)

    def test_gh_capture_and_base_mismatch_use_no_private_stdout(self):
        local = 'LITELLM_BASE_URL=https://synthetic.invalid/v1\nLITELLM_API_KEY=synthetic'
        class Process:
            returncode = 0
            def __init__(self, value): self.stdout = json.dumps({'value': value}).encode()
        with patch.object(Path, 'read_text', return_value=local), patch.object(runner.subprocess, 'run', side_effect=[Process('https://other.invalid/v1'), Process('model')]) as run:
            with self.assertRaises(runner.Rejected): runner.load_configuration(Path('/synthetic/gh'), {})
            self.assertEqual(run.call_count, 2)
            self.assertTrue(all(call.kwargs['capture_output'] is True for call in run.call_args_list))
            self.assertTrue(all(call.kwargs['env'] == {} for call in run.call_args_list))


if __name__ == '__main__': unittest.main()
