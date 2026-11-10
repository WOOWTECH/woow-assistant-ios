#!/usr/bin/env python3
"""Opt-in, maximum four HTTP stream starts; configuration remains in RAM.

Requires a complete current check_chat_streaming_app.py snapshot. Rebuilds from
verified bytes, then loads the specified local dotenv and read-only Actions vars.
No automatic repeat, raw provider output, private environment or URL is recorded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
from check_task_notifications import APPS, MODULES

PRIVATE = ('WOOW_MODEL_TEST_BASE_URL', 'WOOW_MODEL_TEST_MODEL', 'WOOW_MODEL_TEST_API_KEY')
SECRET_FILE = Path('/Users/woowtechmacprointel/.local/share/pi-agent/litellm.env')
DEFAULT_GH = Path('/tmp/woow-ios-tools.juftMc/gh_2.103.3_macOS_amd64/bin/gh')


class Rejected(Exception):
    pass


def unique(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise Rejected('duplicate_json')
        out[key] = value
    return out


def validate_snapshot(root, repo):
    report = json.loads((root / 'report.json').read_bytes(), object_pairs_hook=unique)
    if (report.get('status') != 'PASS' or report.get('focused') is not False
            or report.get('sources_still_current') is not True
            or report.get('release_stream_fixture_absent_from_executable') is not True):
        raise Rejected('offline_preflight')
    required_checks = {m + '-compile' for m, _ in MODULES} | {
        c + s for c in ('Debug', 'Release') for s in ('-iOS-syntax-only', '-compile', '-execute',
        '-chat-compile', '-chat-execute', '-archive-compile', '-archive-execute')
    } | {'model-transport-compile', 'model-transport-regression', 'existing-context-window'}
    checks = report.get('checks', [])
    if (any(type(c.get('exit_code')) is not int or c['exit_code'] != 0 for c in checks)
            or len({c['name'] for c in checks}) != len(checks)
            or not required_checks.issubset({c['name'] for c in checks})):
        raise Rejected('missing_successful_checks')
    by_name = {c['name']: c for c in checks}
    for name, field, expected in [('Debug-execute', 'assertions', 101), ('Release-execute', 'assertions', 75),
                                  ('Debug-chat-execute', 'passed', 573), ('Release-chat-execute', 'passed', 492),
                                  ('Debug-archive-execute', 'assertions', 90), ('Release-archive-execute', 'assertions', 76)]:
        if by_name[name].get('result', {}).get(field) != expected:
            raise Rejected('missing_actual_assertions')
    required = {'Sources/App/' + n + '.swift' for n in APPS}
    required |= {str(p.relative_to(repo)) for name, _ in MODULES for p in (repo / 'Sources' / name).glob('*.swift')}
    required |= {'Sources/App/ContentView.swift', 'scripts/CheckChatStreamingApp.swift', 'scripts/check_chat_streaming_app.py',
                 'scripts/check_task_notifications.py', 'scripts/check_profile_chat_app.py', 'scripts/check_chat_context_window.py',
                 'scripts/CheckProfileChatApp.swift', 'scripts/CheckConversationArchiveApp.swift',
                 'Tests/AssistantModelsTests/ModelProtocolFixture.swift', 'Tests/AssistantModelsTests/ModelClientChecks.swift',
                 'Tests/AssistantModelsTests/ChatContextWindowTests.swift', 'Tests/WoowAssistantUITests/ChatStreamingUITests.swift',
                 'Tests/WoowAssistantUITests/LearningUITestSupport.swift'}
    hashes = report.get('source_sha256', {})
    if set(hashes) != required:
        raise Rejected('source_inventory')
    captured = {}
    for path, expected in hashes.items():
        target = (root / 'source' / path).resolve()
        target.relative_to((root / 'source').resolve())
        data = target.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected or hashlib.sha256((repo / path).read_bytes()).hexdigest() != expected:
            raise Rejected('source_changed')
        captured[path] = data
    return report, captured


def read_dotenv(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('export '):
            line = line[7:].lstrip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, raw = line.split('=', 1)
        key = key.strip()
        if key not in ('LITELLM_BASE_URL', 'LITELLM_API_KEY'):
            continue
        tokens = shlex.split(raw, comments=True, posix=True)
        if key in values or len(tokens) != 1 or not tokens[0]:
            raise Rejected('local_configuration')
        values[key] = tokens[0]
    if set(values) != {'LITELLM_BASE_URL', 'LITELLM_API_KEY'}:
        raise Rejected('local_configuration')
    return values


def match_configuration(local, remote_base, model):
    if (not isinstance(remote_base, str) or not isinstance(model, str)
            or not remote_base.startswith('https://') or not model.strip()
            or local['LITELLM_BASE_URL'].rstrip('/') != remote_base.rstrip('/')):
        raise Rejected('base_mismatch_or_missing_variable')
    return dict(zip(PRIVATE, (remote_base, model, local['LITELLM_API_KEY'])))


def load_configuration(gh, build_env):
    local = read_dotenv(SECRET_FILE.read_text())
    values = []
    for name in PRIVATE[:2]:
        process = subprocess.run([str(gh), 'api', 'repos/WOOWTECH/woow-assistant-ios/actions/variables/' + name],
                                 env=build_env, capture_output=True, timeout=30)
        if process.returncode:
            raise Rejected('actions_variable_unavailable')
        value = json.loads(process.stdout, object_pairs_hook=unique)
        values.append(value.get('value'))
    return match_configuration(local, *values)


def fixed_result(raw):
    value = json.loads(raw, object_pairs_hook=unique)
    enums = {
        'status': {'PASS', 'FAIL'}, 'failure': {'none', 'configuration', 'budget', 'storage', 'completion', 'observation', 'cancellation', 'unknown'},
        'phase': {'configuration', 'complete_stream', 'cancel_stream', 'finished'},
        'transport_failure': {'none', 'cancelled', 'http_rejected', 'timed_out', 'incomplete_response', 'transport_failure', 'model_failure'},
        'cancel_boundary': {'not_attempted', 'not_covered_single_sse_delta', 'not_covered_no_inflight_window', 'cancelled_after_two_observed_deltas_while_transport_inflight'},
    }
    booleans = {'partial_observed', 'partial_never_saved', 'completed_pair_saved', 'encrypted_relaunch_matches', 'learning_unchanged',
                'cancel_covered', 'cancel_no_archive', 'cancel_draft_partial_retained', 'cancel_no_completion_notification',
                'native_ios_ui', 'synthetic_prompts_only', 'personal_keychain', 'private_defaults_on_disk'}
    expected = set(enums) | booleans | {'schema_version', 'maximum_http_attempts', 'http_stream_attempts', 'http_stream_completions', 'sse_text_deltas', 'seconds'}
    if set(value) != expected or any(value[k] not in allowed for k, allowed in enums.items()):
        raise Rejected('private_or_unknown_output')
    if any(type(value[k]) is not bool for k in booleans):
        raise Rejected('output_schema')
    for key in ['schema_version', 'maximum_http_attempts', 'http_stream_attempts', 'http_stream_completions']:
        if type(value[key]) is not int:
            raise Rejected('output_schema')
    if value['schema_version'] != 1 or value['maximum_http_attempts'] != 4 or not 0 <= value['http_stream_completions'] <= value['http_stream_attempts'] <= 4:
        raise Rejected('output_budget')
    if (not isinstance(value['sse_text_deltas'], list) or len(value['sse_text_deltas']) != value['http_stream_attempts']
            or any(type(n) is not int or not 0 <= n <= 100000 for n in value['sse_text_deltas'])
            or type(value['seconds']) not in (int, float) or not 0 <= value['seconds'] <= 240):
        raise Rejected('output_schema')
    if value['status'] == 'PASS' and not all(value[k] for k in ('partial_observed', 'partial_never_saved', 'completed_pair_saved', 'encrypted_relaunch_matches', 'learning_unchanged')):
        raise Rejected('missing_success_assertions')
    if value['cancel_covered'] and not all(value[k] for k in ('cancel_no_archive', 'cancel_draft_partial_retained', 'cancel_no_completion_notification')):
        raise Rejected('missing_cancel_assertions')
    if value['native_ios_ui'] or value['personal_keychain'] or value['private_defaults_on_disk'] or not value['synthetic_prompts_only']:
        raise Rejected('scope_mismatch')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--execute', action='store_true', help='Opt in to actual HTTP after fresh compilation; no retries.')
    parser.add_argument('--gh', type=Path, default=DEFAULT_GH)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    report = {'schema_version': 1, 'status': 'INCOMPLETE', 'actual_http_execution_started': False,
              'source_sha256': {}, 'maximum_http_attempts': 4, 'retry': False}
    # Neither local nor inherited private model fields go to compilation/gh.
    build_env = {k: v for k, v in os.environ.items() if not k.startswith(('WOOW_', 'LITELLM_'))}
    try:
        preflight, captured = validate_snapshot(args.snapshot.resolve(), repo)
        for p in ('scripts/LiveChatStreamingAppSmoke.swift', 'scripts/run_live_chat_streaming.py'):
            captured[p] = (repo / p).read_bytes()
        report['source_sha256'] = {p: hashlib.sha256(b).hexdigest() for p, b in captured.items()}
        report['base_commit'] = preflight['head_at_start']
        report['offline_report_sha256'] = hashlib.sha256((args.snapshot / 'report.json').read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix='woow-live-stream-build-') as temporary:
            root = Path(temporary)
            for p, data in captured.items():
                target = root / p; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
            deadline = time.monotonic() + 240
            def compile(command):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Rejected('compile_deadline')
                p = subprocess.run(command, env=build_env, capture_output=True, timeout=remaining)
                if p.returncode:
                    raise Rejected('compile_failed')
            common = ['swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(root), '-L', str(root)]
            for name, deps in MODULES:
                paths = [str(root / p) for p in sorted(captured) if Path(p).parent == Path('Sources') / name]
                compile([*common, '-emit-module', '-emit-library', '-module-name', name, '-emit-module-path', str(root / (name + '.swiftmodule')),
                         *paths, *['-l' + d for d in deps], '-o', str(root / ('lib' + name + '.dylib'))])
            binary = root / 'live-stream-app'
            compile([*common, *['-l' + name for name, _ in MODULES], '-Xlinker', '-rpath', '-Xlinker', str(root),
                     *[str(root / 'Sources/App' / (n + '.swift')) for n in APPS], str(root / 'scripts/LiveChatStreamingAppSmoke.swift'), '-o', str(binary)])
            report['compile_passed'] = True
            if not all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in report['source_sha256'].items()):
                raise Rejected('source_changed')
            if args.execute:
                credentials = load_configuration(args.gh, build_env)
                report['base_match_verified'] = True; report['actual_http_execution_started'] = True
                process = subprocess.run([str(binary)], env={**build_env, **credentials}, capture_output=True, timeout=240)
                credentials.clear()
                report['result'] = fixed_result(process.stdout)
                if process.returncode != (0 if report['result']['status'] == 'PASS' else 1):
                    raise Rejected('exit_status_mismatch')
                report['status'] = report['result']['status']
            else:
                report['status'] = 'COMPILE_ONLY'
        report['sources_still_current'] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in report['source_sha256'].items())
        if not report['sources_still_current']:
            report['status'] = 'SOURCE_CHANGED'
    except Rejected as error:
        report['status'] = 'FAIL'; report['failure'] = str(error)
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired):
        report['status'] = 'FAIL'; report['failure'] = 'local_or_process_failure'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'source_sha256'}, sort_keys=True))
    return 0 if report['status'] in ('PASS', 'COMPILE_ONLY') else 1


if __name__ == '__main__':
    raise SystemExit(main())
