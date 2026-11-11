from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
import re

import release_ios17 as ios17
from release_ios import ReleaseError


ROOT = Path(__file__).resolve().parents[1]


class DocumentFocusedScopesTests(unittest.TestCase):
    def test_actual_repository_methods_form_exact_disjoint_union(self):
        catalog = ios17.ui_inventory(ROOT)
        expected = set(catalog["shards"]["ui-documents"]["tests"])
        groups = ios17.validate_document_scopes(catalog)
        read, output, chat = (set(groups[name]) for name in ("documents-read", "documents-output", "documents-chat"))
        self.assertTrue(read.isdisjoint(output))
        self.assertTrue(chat.isdisjoint(read | output))
        self.assertEqual(read | output | chat, expected)
        self.assertEqual(len(chat), 3)
        self.assertEqual(len(read), 6)
        self.assertEqual(len(output), 10)
        self.assertEqual(catalog["document_focused_scopes"], groups)
        self.assertEqual(ios17.UI_SHARDS["ui-documents"],
                         ["SkillExecutionUITests", "SkillWorkerSettingsUITests", "SkillPDFAssemblyMultiFileUITests", "ChatPDFAttachmentUITests"])
        for scope, methods in groups.items():
            self.assertNotIn(scope, ios17.UI_SHARDS)
            self.assertEqual(ios17.selected_ui_tests(catalog, scope), methods)
            self.assertEqual(set(ios17.TEST_SCOPES[scope]), set(methods))

    def test_equal_count_wrong_method_overlap_and_duplicates_fail_closed(self):
        catalog = ios17.ui_inventory(ROOT)
        correct = ios17.validate_document_scopes(catalog)
        wrong_method = deepcopy(correct)
        wrong_method["documents-read"][0] = "WoowAssistantUITests/SkillExecutionUITests/testNotInSource"
        overlapping = deepcopy(correct)
        overlapping["documents-output"][0] = overlapping["documents-read"][0]
        duplicated = deepcopy(correct)
        duplicated["documents-read"][0] = duplicated["documents-read"][1]
        for invalid in (wrong_method, overlapping, duplicated):
            with self.subTest(invalid=invalid), self.assertRaises(ReleaseError):
                self.assertEqual(sum(map(len, invalid.values())), sum(map(len, correct.values())))
                ios17.validate_document_scopes(catalog, invalid)

    def test_class_selector_extra_scope_and_empty_scope_are_rejected(self):
        catalog = ios17.ui_inventory(ROOT)
        correct = ios17.validate_document_scopes(catalog)
        broad = deepcopy(correct)
        broad["documents-read"] = ["WoowAssistantUITests/SkillExecutionUITests"]
        for invalid in (broad, {**correct, "documents-extra": []},
                        {**correct, "documents-read": []}, {"documents-read": correct["documents-read"]}):
            with self.subTest(invalid=invalid), self.assertRaises(ReleaseError):
                ios17.validate_document_scopes(catalog, invalid)

    def test_new_renamed_or_removed_actual_source_method_fails_inventory(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / "Tests/WoowAssistantUITests"
            target.mkdir(parents=True)
            for name in ios17.UI_SHARDS["ui-documents"]:
                (target / (name + ".swift")).write_text(
                    (ROOT / "Tests/WoowAssistantUITests" / (name + ".swift")).read_text())
            for name in ios17.LIVE_UI_CLASSES:
                (target / (name + ".swift")).write_text(
                    "final class " + name + ": XCTestCase { func testSyntheticLive() {} }")
            mapping = {"ui-documents": ios17.UI_SHARDS["ui-documents"]}
            ios17.ui_inventory(root, mapping)
            path = target / "SkillExecutionUITests.swift"
            original = path.read_text()
            declaration = "final class SkillExecutionUITests: XCTestCase {"
            self.assertEqual(original.count(declaration), 1)
            name = "testNativePickerCancellationDoesNotReadOrExtract"
            mutations = [original.replace(declaration, declaration + "\nfunc testNewDocumentFlow() {}\n"),
                         original.replace(name, "testRenamedNativePickerCancellation"),
                         original.replace(name, "scenarioNativePickerCancellation")]
            for source in mutations:
                with self.subTest(mutation=mutations.index(source)):
                    path.write_text(source)
                    with self.assertRaisesRegex(ReleaseError, "聯集必須精確等於"):
                        ios17.ui_inventory(root, mapping)

    def test_equal_count_passing_other_scope_cannot_pass_own_completion_gate(self):
        catalog = ios17.ui_inventory(ROOT)
        groups = catalog["document_focused_scopes"]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tests.log"
            for scope, expected in groups.items():
                other = groups["documents-output" if scope == "documents-read" else "documents-read"]
                summary = {"result": "Passed", "totalTestCount": len(expected), "passedTests": len(expected),
                           "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
                wrong_method_same_count = [other[0], *expected[1:]]
                for selected, accepted in ((expected, True), (wrong_method_same_count, False)):
                    path.write_text("".join("Test Case '-[WoowAssistantUITests.%s %s]' passed (1.0 seconds).\n" %
                                            tuple(name.split("/")[1:]) for name in selected))
                    result = ios17.test_completion(summary, path, expected, True)
                    self.assertEqual(result["verified"], accepted)

    def test_assembly_focused_scopes_select_distinct_actual_methods_and_keep_completion_gate(self):
        catalog = ios17.ui_inventory(ROOT)
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        selected = []
        for scope in ("pdf-assembly", "pdf-assembly-uikit", "pdf-assembly-copy", "pdf-assembly-multi", "pdf-pair-coordinated"):
            expected = ios17.selected_ui_tests(catalog, scope)
            self.assertEqual(len(expected), 1)
            self.assertIn(expected[0], catalog["document_focused_scopes"]["documents-output"])
            match = re.search(r"^            " + re.escape(scope) + r"\)\n\s+test_filters=\(([^\n]+)\)", workflow, re.M)
            self.assertIsNotNone(match)
            self.assertEqual(match.group(1).split(), ["-only-testing:" + expected[0]])
            selected.extend(expected)
            options = re.search(r"test_scope:\n.*?options: \[([^\]]+)\]", workflow, re.S).group(1)
            self.assertIn(scope, [s.strip() for s in options.split(",")])
            gate = next(line for line in workflow.splitlines() if "always()" in line and "VALIDATION_SCOPE" not in line and '"pdf-assembly"' in line)
            self.assertIn('"' + scope + '"', gate)
            timeout = next(line for line in workflow.splitlines() if "timeout-minutes:" in line and '"pdf-assembly"' in line)
            self.assertIn('"' + scope + '"', timeout)
            self.assertIn("&& 20 || 55", timeout)
        self.assertEqual(len(set(selected)), 5)

    def test_pair_focus_requires_its_actual_source_method_not_another_passing_assembly(self):
        catalog = ios17.ui_inventory(ROOT)
        expected = ["WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testUserChosenCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages"]
        self.assertEqual(ios17.selected_ui_tests(catalog, "pdf-assembly-multi"), expected)
        self.assertIn(expected[0], catalog["document_focused_scopes"]["documents-output"])
        summary = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                   "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tests.log"
            other = ios17.selected_ui_tests(catalog, "pdf-assembly-copy")
            for methods, accepted in ((expected, True), (other, False)):
                path.write_text("".join("Test Case '-[WoowAssistantUITests.%s %s]' passed (1.0 seconds).\n" %
                                        tuple(method.split("/")[1:]) for method in methods))
                self.assertEqual(ios17.test_completion(summary, path, expected, True)["verified"], accepted)

    def test_directory_candidate_cannot_be_satisfied_by_baseline_pair(self):
        catalog = ios17.ui_inventory(ROOT)
        expected = ["WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testDirectoryCoordinatedFixtureCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages"]
        self.assertEqual(ios17.selected_ui_tests(catalog, "pdf-pair-coordinated"), expected)
        summary = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                   "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tests.log"
            baseline = ios17.selected_ui_tests(catalog, "pdf-assembly-multi")
            for methods, accepted in ((expected, True), (baseline, False)):
                path.write_text("".join("Test Case '-[WoowAssistantUITests.%s %s]' passed (1.0 seconds).\n" %
                                        tuple(method.split("/")[1:]) for method in methods))
                self.assertEqual(ios17.test_completion(summary, path, expected, True)["verified"], accepted)


if __name__ == "__main__":
    unittest.main()
