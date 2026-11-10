import copy
import json
import unittest

from check_live_replay_references_app import CheckFailure, ROOTS, clean_environment, validate_live


def fixture():
    pages = [{"index": i, "url": url, "textSHA256": "1" * 64, "quoteSHA256": "2" * 64,
              "textCharacters": 600, "capturedAt": 1800000000.0} for i, url in enumerate(ROOTS)]
    cases = []
    for index, name in enumerate(["savedPreference", "currentPriority"]):
        cases.append({"id": name, "passed": True, "failure": "none", "clientAttempts": 2, "clientResponses": 2,
                      "modelErrors": [], "answerInputVerified": True, "judgeLedgerVerified": True,
                      "expectedPrefixMatched": True, "startsWithSavedPrefix": index == 0, "startsWithCurrentPrefix": index == 1,
                      "observedURLStringsMentioned": 2, "answerSHA256": "3" * 64, "routeSuccessDelta": 1,
                      "encryptedReadbackVerified": True, "referencesUnchanged": True,
                      "observations": copy.deepcopy(pages), "milliseconds": 1000})
    return {"passed": True, "failure": "none", "preparation": pages, "cases": cases,
            "clientAttempts": 4, "clientResponses": 4, "milliseconds": 3000}


class ReplayLivePublicationTests(unittest.TestCase):
    def rejects(self, value):
        with self.assertRaises(CheckFailure): validate_live(json.dumps(value).encode())

    def test_valid_pass(self):
        self.assertEqual(validate_live(json.dumps(fixture()).encode()), fixture())

    def test_valid_source_failure_before_model(self):
        value = {"passed": False, "failure": "sources", "preparation": [], "cases": [],
                 "clientAttempts": 0, "clientResponses": 0, "milliseconds": 75000}
        self.assertEqual(validate_live(json.dumps(value).encode()), value)

    def test_reject_raw_answer(self):
        value = fixture(); value["cases"][0]["answer"] = "must never survive"; self.rejects(value)

    def test_reject_raw_error(self):
        value = fixture(); value["error"] = "must never survive"; self.rejects(value)

    def test_reject_unknown_provider_url(self):
        value = fixture(); value["preparation"][0]["url"] = "https://private.invalid/"; self.rejects(value)

    def test_reject_wrong_observation_order(self):
        value = fixture(); value["cases"][0]["observations"].reverse(); self.rejects(value)

    def test_reject_duplicate_fields(self):
        raw = json.dumps(fixture()).replace('"passed": true', '"passed": true, "passed": true', 1)
        with self.assertRaises(CheckFailure): validate_live(raw.encode())

    def test_reject_budget_overflow(self):
        value = fixture(); value["clientAttempts"] = 9; self.rejects(value)

    def test_reject_counter_mismatch(self):
        value = fixture(); value["clientAttempts"] = 5; self.rejects(value)

    def test_reject_boolean_counter(self):
        value = fixture(); value["cases"][0]["routeSuccessDelta"] = True; self.rejects(value)

    def test_reject_saved_prefix_for_override(self):
        value = fixture(); value["cases"][1]["startsWithSavedPrefix"] = True; self.rejects(value)

    def test_reject_unverified_ledger(self):
        value = fixture(); value["cases"][0]["judgeLedgerVerified"] = False; self.rejects(value)

    def test_reject_missing_judge_receipt(self):
        value = fixture(); value["cases"][0]["routeSuccessDelta"] = 0; self.rejects(value)

    def test_reject_missing_requested_literal_url(self):
        value = fixture(); value["cases"][0]["observedURLStringsMentioned"] = 1; self.rejects(value)

    def test_reject_missing_encrypted_readback(self):
        value = fixture(); value["cases"][0]["encryptedReadbackVerified"] = False; self.rejects(value)

    def test_reject_nan_time(self):
        value = fixture(); value["preparation"][0]["capturedAt"] = float("nan"); self.rejects(value)

    def test_reject_response_data_in_hash(self):
        value = fixture(); value["cases"][0]["answerSHA256"] = "raw content"; self.rejects(value)

    def test_reject_missing_case(self):
        value = fixture(); value["cases"].pop(); value["clientAttempts"] = value["clientResponses"] = 2; self.rejects(value)

    def test_reject_unbounded_report(self):
        with self.assertRaises(CheckFailure): validate_live(b" " * 32769)

    def test_reject_error_response_body(self):
        value = fixture(); value["cases"][0]["modelErrors"] = [{"kind": "httpStatus", "statusCode": 400, "body": "private"}]; self.rejects(value)

    def test_compile_environment_excludes_credentials(self):
        self.assertEqual(clean_environment({"PATH": "/usr/bin", "WOOW_MODEL_TEST_API_KEY": "synthetic", "UNRELATED_TOKEN": "synthetic"}), {"PATH": "/usr/bin"})

    @staticmethod
    def diagnostic():
        value = fixture(); value["cases"] = value["cases"][1:]
        value["clientAttempts"] = value["clientResponses"] = 2
        value["cases"][0]["diagnostic"] = {
            "learningStatus": "saved", "storeAvailable": True, "storeErrorPresent": False, "browserErrorPresent": False,
            "referenceValid": True, "goalUnchanged": True, "routeIdentityUnchanged": True, "observationsNewerThanRoute": True,
            "goalSHA256": "4" * 64, "wireOutcome": "done", "wireEvidenceCount": 2, "quotesAbsentFromObservation": 0,
            "quotesContainingURLAlias": 0, "productionOutcome": "done", "productionSkipReason": "draftDisabled",
            "productionCitationCount": 2, "parserReplayMatched": True}
        return value

    def test_diagnostic_only_same_case(self):
        value = self.diagnostic()
        self.assertEqual(validate_live(json.dumps(value).encode(), diagnostic_only=True), value)

    def test_diagnostic_preserves_failed_judgment(self):
        value = self.diagnostic(); row = value["cases"][0]
        value["passed"] = row["passed"] = False; value["failure"] = row["failure"] = "judgment"
        row["routeSuccessDelta"] = 0
        row["diagnostic"].update(learningStatus="notConfirmed", productionOutcome="unknown", productionSkipReason="invalidJudgment", productionCitationCount=0)
        self.assertEqual(validate_live(json.dumps(value).encode(), diagnostic_only=True), value)

    def test_diagnostic_cannot_relabel_missing_receipt_pass(self):
        value = self.diagnostic(); value["cases"][0]["routeSuccessDelta"] = 0
        with self.assertRaises(CheckFailure): validate_live(json.dumps(value).encode(), diagnostic_only=True)

    def test_diagnostic_rejects_raw_fields_and_unknown_categories(self):
        for key, bad in [("rawReply", "forbidden"), ("learningStatus", "arbitrary runtime text"),
                         ("productionSkipReason", "private error"), ("wireOutcome", "raw response"),
                         ("wireEvidenceCount", True), ("goalSHA256", "raw goal")]:
            value = self.diagnostic(); value["cases"][0]["diagnostic"][key] = bad
            with self.assertRaises(CheckFailure): validate_live(json.dumps(value).encode(), diagnostic_only=True)

    def test_diagnostic_rejects_unmatched_production_replay(self):
        value = self.diagnostic(); value["cases"][0]["diagnostic"]["parserReplayMatched"] = False
        with self.assertRaises(CheckFailure): validate_live(json.dumps(value).encode(), diagnostic_only=True)

    def test_diagnostic_rejects_other_case_and_extra_case(self):
        value = self.diagnostic(); value["cases"][0]["id"] = "savedPreference"
        with self.assertRaises(CheckFailure): validate_live(json.dumps(value).encode(), diagnostic_only=True)
        with self.assertRaises(CheckFailure): validate_live(json.dumps(fixture()).encode(), diagnostic_only=True)

    def test_diagnostic_not_accepted_as_original_full_run(self):
        self.rejects(self.diagnostic())


if __name__ == "__main__":
    unittest.main()
