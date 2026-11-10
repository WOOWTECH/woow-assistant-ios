import copy
import json
from pathlib import Path
import tempfile
import unittest

from check_live_multi_source_references import CheckFailure, clean_environment, prior_usage, validate_live


def passing_fixture():
    cases = []
    for name in ["savedPreference", "currentOverride", "referenceIsNotEvidence"]:
        cases.append({"id": name, "passed": True, "failure": "none", "modelCalls": 1, "modelResponses": 1,
                      "modelErrors": [],
                      "inputBoundaryVerified": True, "prefixMatched": True, "citedOrigins": 2, "findingCount": 1,
                      "privateCitationCount": 0, "milliseconds": 10,
                      "receipts": [{"source": "source-" + str(i), "page": i, "urlSHA256": "a" * 64,
                                    "textSHA256": "b" * 64, "capturedAt": 1700000000} for i in [1, 2]],
                      "citations": [{"source": "source-" + str(i), "page": i, "quoteSHA256": "c" * 64,
                                     "utf8Bytes": 12, "exactObservedRange": True} for i in [1, 2]]})
    return {"passed": True, "failure": "none", "cases": cases, "modelCalls": 3,
            "priorModelCalls": 1, "cumulativeModelCalls": 4, "diagnosticOnly": False, "forgedReplayRejected": True,
            "forgedReplayModelCalls": 1, "forgedReplayNetworkRequests": 0, "milliseconds": 30}


class LiveMultiSourceReferenceRunnerTests(unittest.TestCase):
    def reject(self, value):
        with self.assertRaisesRegex(CheckFailure, "^invalid_live_report$"):
            validate_live(json.dumps(value).encode())

    def testExactProofAndFailedOutcomeRemainDistinct(self):
        good = passing_fixture()
        self.assertEqual(validate_live(json.dumps(good).encode()), good)
        failed = copy.deepcopy(good)
        failed.update(passed=False, failure="preference", cases=failed["cases"][:1], modelCalls=1,
                      cumulativeModelCalls=2, forgedReplayRejected=False, forgedReplayModelCalls=0)
        failed["cases"][0].update(passed=False, failure="preference", prefixMatched=False)
        self.assertFalse(validate_live(json.dumps(failed).encode())["passed"])
        failed["passed"] = True
        self.reject(failed)

    def testNoArbitraryNestedContentCanBecomeEvidence(self):
        for path in [[], ["cases", 0], ["cases", 0, "receipts", 0], ["cases", 0, "citations", 0]]:
            with self.subTest(path=path):
                fixture = passing_fixture(); current = fixture
                for key in path:
                    current = current[key]
                current["raw_private_response"] = "SYNTHETIC_NEVER_PERSIST"
                self.reject(fixture)
        fixture = passing_fixture()
        fixture["cases"][0]["receipts"][0]["urlSHA256"] = "https://private.invalid/secret"
        self.reject(fixture)

    def testCitationAndPreferenceEvidenceCannotBeRelaxed(self):
        mutations = [lambda c: c.update(prefixMatched=False), lambda c: c.update(inputBoundaryVerified=False),
                     lambda c: c.update(privateCitationCount=1), lambda c: c.update(citedOrigins=1),
                     lambda c: c["citations"][0].update(exactObservedRange=False),
                     lambda c: c["citations"][0].update(page=15),
                     lambda c: c["citations"][0].update(source="source-2"),
                     lambda c: c["receipts"].append(copy.deepcopy(c["receipts"][0])),
                     lambda c: c["receipts"][0].update(capturedAt=float("nan"))]
        for mutation in mutations:
            fixture = passing_fixture(); mutation(fixture["cases"][0]); self.reject(fixture)

    def testBoundsDuplicatesAndReplayAreStrict(self):
        for field, value in [("modelCalls", 13), ("modelCalls", True), ("milliseconds", 570001),
                             ("forgedReplayRejected", False), ("forgedReplayNetworkRequests", 1)]:
            fixture = passing_fixture(); fixture[field] = value; self.reject(fixture)
        fixture = passing_fixture(); fixture["cases"].reverse(); self.reject(fixture)
        for raw in [b'{"passed":true,"passed":false}', b"x" * 65537, b"not-json"]:
            with self.assertRaisesRegex(CheckFailure, "^invalid_live_report$"):
                validate_live(raw)

    def testCompilerEnvironmentContainsNoAdjacentSecrets(self):
        environment = {"PATH": "/usr/bin", "HOME": "/synthetic", "WOOW_MODEL_TEST_API_KEY": "SYNTHETIC",
                       "WOOW_MODEL_TEST_BASE_URL": "https://private.invalid", "WOOW_HA_MCP_TEST_URL": "SYNTHETIC",
                       "OPENAI_API_KEY": "SYNTHETIC", "UNRELATED_TOKEN": "SYNTHETIC", "DYLD_INSERT_LIBRARIES": "SYNTHETIC"}
        self.assertEqual(clean_environment(environment), {"PATH": "/usr/bin", "HOME": "/synthetic"})

    def testSafeClientErrorsAreClosedAndNumeric(self):
        failed = passing_fixture()
        failed.update(passed=False, failure="modelFailure", cases=failed["cases"][:1], modelCalls=1,
                      cumulativeModelCalls=2, diagnosticOnly=True, forgedReplayRejected=False, forgedReplayModelCalls=0)
        failed["cases"][0].update(passed=False, failure="modelFailure", modelResponses=0,
                                   modelErrors=[{"kind": "httpStatus", "statusCode": 401}])
        self.assertEqual(validate_live(json.dumps(failed).encode()), failed)
        for error in [{"kind": "httpStatus", "statusCode": "401"},
                      {"kind": "httpStatus", "statusCode": 999},
                      {"kind": "httpStatus", "statusCode": True},
                      {"kind": "transportFailure", "statusCode": 401},
                      {"kind": "https://private.invalid", "statusCode": 0},
                      {"kind": "httpStatus", "statusCode": 401, "body": "PRIVATE"}]:
            bad = copy.deepcopy(failed); bad["cases"][0]["modelErrors"] = [error]; self.reject(bad)

    def testCrossAttemptBudgetAndDiagnosticLimit(self):
        good = passing_fixture()
        for changes in [{"priorModelCalls": 11, "cumulativeModelCalls": 14},
                        {"cumulativeModelCalls": 3}, {"diagnosticOnly": True}]:
            bad = copy.deepcopy(good); bad.update(changes); self.reject(bad)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "previous.json"
            path.write_text(json.dumps({"live_attempted": True, "checks": [{"name": "live-run", "result": good}]}))
            count, digest = prior_usage(path)
            self.assertEqual(count, 4); self.assertEqual(len(digest), 64)
            legacy = {"modelCalls": 1, "cases": [{"modelCalls": 1}]}
            path.write_text(json.dumps({"live_attempted": True, "checks": [{"name": "live-run", "result": legacy}]}))
            self.assertEqual(prior_usage(path)[0], 1)
            legacy["modelCalls"] = 12
            path.write_text(json.dumps({"live_attempted": True, "checks": [{"name": "live-run", "result": legacy}]}))
            with self.assertRaises(CheckFailure): prior_usage(path)


if __name__ == "__main__":
    unittest.main()
