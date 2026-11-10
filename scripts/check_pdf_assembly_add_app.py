#!/usr/bin/env python3
"""Snapshot shared standalone/hosted App checks; execute real macOS PDFKit."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from check_pdf_assembly_pair import run


GROUPS = {"selectionAndReadConsent", "cancelledAndInvalidAdd", "separateGrantsAndSourceLimit", "clearFencesLateCompletion"}
HOSTED_METHODS = {
    "testSingleSelectionRequestsRequireReadApproval",
    "testCancelledInvalidAndLateAddPreserveReviewedResult",
    "testSeparateReadGrantsInterleaveActualPagesAndEnforceSourceLimit",
    "testClearFencesLatePickerAndActualReadCompletion",
}


def local_result(stdout):
    value = json.loads(stdout)
    groups = value.get('groups')
    if (not isinstance(groups, dict) or set(groups) != GROUPS
            or any(type(n) is not int or n <= 0 for n in groups.values())
            or type(value.get('passed')) is not int or value['passed'] != sum(groups.values())
            or type(value.get('failed')) is not int or value['failed'] != 0
            or any(value.get(k) is not True for k in ['actual_app_sources', 'actual_pdfkit', 'actual_file_document'])
            or value.get('native_picker_UI') is not False):
        raise ValueError('unexpected_check_output')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    hashes = {}
    result = {'uses_stubs': False, 'native_picker_or_exporter_UI_test': False,
              'source_snapshot_sha256': hashes, 'hosted_xctest_executed': False,
              'hosted_xctest_selectors': ['AssistantSkillsTests/PDFAssemblyAddAppIntegrationTests/' + name
                                          for name in sorted(HOSTED_METHODS)]}
    with tempfile.TemporaryDirectory(prefix='woow-assembly-add-') as temporary:
        output = Path(temporary)

        def snapshot(relative):
            data = (repo / relative).read_bytes()
            hashes[str(relative)] = hashlib.sha256(data).hexdigest()
            destination = output / 'source' / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            return destination

        support, session, view, harness = map(snapshot, [
            'Sources/App/SkillExecutionUITestSupport.swift', 'Sources/App/SkillPDFAssemblySession.swift',
            'Sources/App/SkillPDFAssemblyView.swift', 'scripts/CheckPDFAssemblyAddApp.swift'])
        declarations = set(re.findall(r'func (test\w+)\(\) async throws', harness.read_text()))
        if declarations != HOSTED_METHODS:
            raise ValueError('hosted_entry_inventory')
        picker = snapshot('Sources/App/PDFNativePicker.swift')
        legacy = snapshot('scripts/SkillPDFAssemblyAppChecks.swift')
        ui = [snapshot('Tests/WoowAssistantUITests/' + name) for name in
              ['SkillPDFAssemblyMultiFileUITests.swift', 'SkillExecutionUITests.swift']]
        for name in ['scripts/check_pdf_assembly_add_app.py', 'scripts/check_pdf_assembly_pair.py',
                     'scripts/check_skill_fixture_diagnostics.py']:
            snapshot(name)
        sources = [snapshot(p.relative_to(repo)) for p in sorted((repo / 'Sources/AssistantSkills').glob('*.swift'))
                   if p.name != 'SkillLearningService.swift']
        catalog = snapshot('Sources/AssistantSkills/Resources/MikaBundledSkills.json')
        run(['swiftc', '-warnings-as-errors', '-parse-as-library', '-D', 'SKILL_EXECUTION_SMOKE',
             '-emit-module', '-emit-library', '-static', '-module-name', 'AssistantSkills',
             '-emit-module-path', output / 'AssistantSkills.swiftmodule', *sources,
             '-o', output / 'libAssistantSkills.a'], repo, 180)
        for name, flags in [('debug', ['-D', 'DEBUG']), ('release', [])]:
            contents = output / (name + '.app') / 'Contents'
            binary = contents / 'MacOS' / 'Checks'
            binary.parent.mkdir(parents=True)
            resources = contents / 'Resources'; resources.mkdir()
            (resources / 'MikaBundledSkills.json').write_bytes(catalog.read_bytes())
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'Checks', 'CFBundleIdentifier': 'local.woow.assembly-add.' + name,
                'CFBundlePackageType': 'APPL'}))
            run(['swiftc', '-warnings-as-errors', '-parse-as-library', '-D', 'PDF_ASSEMBLY_ADD_APP_CHECKS',
                 *flags, '-I', output, '-L', output, '-lAssistantSkills',
                 support, session, view, harness, '-o', binary], repo, 180)
            stdout = run([binary], repo, 60)
            checked = local_result(stdout)
            result[name + '_passed'] = checked['passed']
            result[name + '_groups'] = checked['groups']
            # Existing actual read/prepare/cancel/export-snapshot regressions,
            # including a held NSFileCoordinator read, remain unchanged.
            run(['swiftc', '-warnings-as-errors', '-parse-as-library', *flags,
                 '-I', output, '-L', output, '-lAssistantSkills',
                 support, session, view, legacy, '-o', binary], repo, 180)
            previous = json.loads(run([binary], repo, 90))
            if previous.get('failure') or previous['passed'] != previous['total']:
                raise ValueError('legacy_regression')
            result[name + '_existing_app_passed'] = previous['passed']
            gate = output / (name + '-picker-gates')
            run(['swiftc', '-warnings-as-errors', '-parse-as-library', *flags,
                 '-D', 'SKILL_EXECUTION_NATIVE_PICKER_CHECKS', picker, ui[1], '-o', gate], repo, 60)
            gates = run([gate], repo, 10)
            matched = re.match(r'PASS (?:DEBUG|Release) (\d+) checks:', gates)
            if not matched:
                raise ValueError('picker_gates_output')
            result[name + '_picker_gate_passed'] = int(matched.group(1))
            run(['swiftc', '-parse', '-target', 'arm64-apple-ios17.0', *flags,
                 support, session, view, picker, harness, *ui], repo, 30)
            result[name + '_ios17_syntax_parse'] = True
            print(name.upper() + ' ADD_APP_CHECKS=' + str(checked['passed']) + ' GROUPS=' + str(len(checked['groups'])), flush=True)
            print(name.upper() + ' EXISTING_APP=' + str(previous['passed']) + ' PICKER_GATES=' + matched.group(1), flush=True)
        captured_module = {path for path in hashes if path.startswith('Sources/AssistantSkills/') and path.endswith('.swift')}
        current_module = {str(path.relative_to(repo)) for path in (repo / 'Sources/AssistantSkills').glob('*.swift')
                          if path.name != 'SkillLearningService.swift'}
        result['live_sources_match_snapshot'] = captured_module == current_module and all(
            hashlib.sha256((repo / path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
        if not result['live_sources_match_snapshot']:
            raise ValueError('sources_changed_during_check')
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print('ADD_APP_PASS nativeUI=pending', flush=True)


if __name__ == '__main__':
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit('ADD_APP_TIMEOUT')
    except subprocess.CalledProcessError:
        raise SystemExit('ADD_APP_FAILED')
    except ValueError:
        raise SystemExit('ADD_APP_EVIDENCE_INVALID')
