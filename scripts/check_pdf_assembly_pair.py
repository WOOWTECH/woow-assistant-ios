#!/usr/bin/env python3
"""Snapshot real sources, check native PDFKit pair/gates and App types; no UI claim."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import tempfile
from copy_skill_fixture_diagnostics import PAIR_MARKER, checked


def run(args, repo, timeout):
    # The compiler frontend belongs to this invocation's process group only.
    with subprocess.Popen(list(map(str, args)), cwd=repo, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, start_new_session=True) as process:
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        if process.returncode:
            print(output, end='', flush=True)
            raise subprocess.CalledProcessError(process.returncode, args)
        return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    owned = ['Sources/App/SkillExecutionUITestSupport.swift', 'Sources/App/SkillPDFAssemblySession.swift',
             'Sources/App/SkillPDFAssemblyView.swift', 'Tests/WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests.swift']
    hashes = {}
    result = {'native_picker_or_exporter_UI_test': False, 'uses_stubs': False, 'source_snapshot_sha256': hashes}
    with tempfile.TemporaryDirectory(prefix='woow-pdf-pair-check-') as temporary:
        output = Path(temporary)

        def snapshot(relative):
            data = (repo / relative).read_bytes()
            hashes[str(relative)] = hashlib.sha256(data).hexdigest()
            destination = output / 'source' / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            return destination

        support, session, view, tests = map(snapshot, owned)
        snapshot('scripts/check_pdf_assembly_pair.py')
        snapshot('scripts/copy_skill_fixture_diagnostics.py')
        sources = [snapshot(p.relative_to(repo)) for p in sorted((repo / 'Sources/AssistantSkills').glob('*.swift'))
                   if p.name != 'SkillLearningService.swift']
        catalog = snapshot(Path('Sources/AssistantSkills/Resources/MikaBundledSkills.json'))
        run(['swiftc', '-warnings-as-errors', '-parse-as-library', '-D', 'SKILL_EXECUTION_SMOKE',
             '-emit-module', '-emit-library', '-static', '-module-name', 'AssistantSkills',
             '-emit-module-path', output / 'AssistantSkills.swiftmodule', *sources,
             '-o', output / 'libAssistantSkills.a'], repo, 180)
        for name, flags in [('debug', ['-D', 'DEBUG']), ('release', [])]:
            binary = output / name
            dependencies = ['-I', output, '-L', output, '-lAssistantSkills'] if name == 'debug' else []
            run(['swiftc', '-warnings-as-errors', '-parse-as-library', '-D', 'SKILL_ASSEMBLY_PAIR_CHECKS',
                 '-D', 'SKILL_ASSEMBLY_PAIR_MODULE', *flags, *dependencies, support, tests, '-o', binary], repo, 180)
            stdout = run([binary, catalog], repo, 120)
            lines = stdout.splitlines()
            observations = []
            for line in lines[:-1]:
                if name != 'debug' or not line.startswith(PAIR_MARKER):
                    raise ValueError('unexpected_diagnostic_output')
                observations.append(checked(json.loads(line[len(PAIR_MARKER):])))
            if name == 'debug':
                if (len(observations) != 4 or len({o['namespace'] for o in observations}) != 1
                        or {(o.get('role'), o['phase'], o.get('ordinal')) for o in observations}
                        != {(role, phase, 0) for role in ('A', 'B') for phase in ('created', 'existing')}
                        or any(o['version'] != 2 or o['evidence']['status'] != 'valid' for o in observations)):
                    raise ValueError('invalid_pair_baseline_evidence')
            match = re.fullmatch(r'PAIR_CHECKS passed=(\d+) nativePicker=false', lines[-1] if lines else '')
            if not match:
                raise ValueError('unexpected_check_output')
            result[name + '_passed'] = int(match.group(1))
            # Real AssistantSkills types + the exact App Session and FileDocument.
            # The iOS View body still needs the native CI SDK for typechecking.
            run(['swiftc', '-warnings-as-errors', '-typecheck', *flags, '-I', output,
                 support, session, view], repo, 120)
            run(['swiftc', '-parse', '-target', 'arm64-apple-ios17.0', *flags,
                 support, session, view, tests], repo, 30)
            result[name + '_app_logic_typecheck'] = True
            result[name + '_ios17_syntax_parse'] = True
            result[name + '_pair_baseline_records'] = len(observations)
            print(name.upper() + ' ' + lines[-1], flush=True)
        # Fail rather than attribute an old snapshot's pass to edited sources.
        result['live_sources_match_snapshot'] = all(
            hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
        if not result['live_sources_match_snapshot']:
            raise ValueError('sources_changed_during_check')
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('PAIR_APP_TYPES_AND_IOS17_PARSE_PASS nativeUI=pending', flush=True)


if __name__ == '__main__':
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit('PAIR_CHECK_TIMEOUT')
    except subprocess.CalledProcessError:
        raise SystemExit('PAIR_CHECK_FAILED')
    except ValueError:
        raise SystemExit('PAIR_CHECK_EVIDENCE_INVALID')
