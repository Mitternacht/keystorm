#!/usr/bin/env python3
"""Offline checks for the performance gate, using synthetic timings only."""
import importlib.util
import contextlib
import datetime
import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("compare_performance", Path(__file__).with_name("compare_performance.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


def report(clean=500, count=100):
    value = {
        "schemaVersion": 1, "buildConfiguration": "Release", "textModelInstalled": True,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "hostWorkspaceInitialized": False,
        "artifactIdentity": {
            "schemaVersion": 1, "bundleIdentifier": "dev.mitternacht.Keystorm",
            "marketingVersion": "1.0", "buildNumber": "1",
            "mainExecutable": "Contents/MacOS/Keystorm",
            "machoUUIDs": {"Contents/MacOS/Keystorm": [
                {"architecture": "arm64", "uuid": "01234567-89AB-CDEF-0123-456789ABCDEF"}]},
        },
        "buildInstrumentation": {"schemaVersion": 1, "method": performance.INSTRUMENTATION_METHOD,
            "llvmProfileInstrumented": False, "binaries": [{"path": "Contents/MacOS/Keystorm",
                "architecture": "arm64", "llvmProfileSections": []}]},
        "hardwareModel": "Mac17,4", "physicalMemoryBytes": 16 * 1024 ** 3,
        "operatingSystem": "reference macOS", "speechModelID": "speech",
        "speechModelRevision": "speech-pinned", "textModelID": "text", "textModelRevision": "text-pinned",
        "lowPowerMode": False, "thermalStateAtStart": 0, "thermalStateAtEnd": 0,
        "fixture": {"sha256": "same-source"}, "requestedWarmPasses": count,
        "passes": [],
    }
    for index, scenario in enumerate(["cold", "prewarmedFirst"] + ["warm"] * count):
        value["passes"].append({"index": index, "scenario": scenario, "insertedExactlyOnce": True,
                               "rawMilliseconds": 150, "cleanMilliseconds": clean,
                               "finishToCleanMilliseconds": clean + 150,
                               "deliveryMilliseconds": 1, "receiptSaveMilliseconds": 2,
                               "resourcesAfterPass": {"workerPID": 42, "speechModelLoaded": 1,
                                                      "textModelLoaded": 1, "speechModelLoads": 1,
                                                      "textModelLoads": 1}})
    return value


class PerformanceGateTests(unittest.TestCase):
    def test_qualification_requires_explicit_host_isolation(self):
        for missing in (None, "false", 0):
            candidate = report()
            if missing is None:
                candidate.pop("hostWorkspaceInitialized")
            else:
                candidate["hostWorkspaceInitialized"] = missing
            with self.subTest(value=missing), self.assertRaisesRegex(ValueError, "hostWorkspaceInitialized"):
                performance.compare(report(), candidate, qualify=True)

    def test_qualification_cannot_omit_or_forge_warm_residency_evidence(self):
        for key in ("workerPID", "speechModelLoaded", "textModelLoaded", "speechModelLoads", "textModelLoads"):
            for invalid in (None, 0, True, "1", -1):
                candidate = report()
                for sample in candidate["passes"]:
                    if invalid is None:
                        sample["resourcesAfterPass"].pop(key)
                    else:
                        sample["resourcesAfterPass"][key] = invalid
                with self.subTest(key=key, value=invalid), self.assertRaises(ValueError):
                    performance.compare(report(), candidate, qualify=True)
        candidate = report()
        candidate["passes"][-1]["resourcesAfterPass"] = None
        with self.assertRaises(ValueError):
            performance.compare(report(), candidate, qualify=True)

    def test_legacy_without_instrumentation_is_diagnostic_only(self):
        legacy = report()
        legacy.pop("buildInstrumentation")
        for qualify in (False, True):
            with self.subTest(qualify=qualify), self.assertRaisesRegex(ValueError, "buildInstrumentation"):
                performance.compare(legacy, report(), qualify=qualify)

    def test_known_instrumented_runs_compare_but_never_qualify(self):
        instrumented = report()
        instrumented["buildInstrumentation"]["llvmProfileInstrumented"] = True
        instrumented["buildInstrumentation"]["binaries"][0]["llvmProfileSections"] = ["__llvm_prf_cnts"]
        self.assertTrue(performance.compare(instrumented, instrumented)["passed"])
        with self.assertRaisesRegex(ValueError, "instrumentation must be absent"):
            performance.compare(instrumented, instrumented, qualify=True)
        with self.assertRaisesRegex(ValueError, "Incomparable.*buildInstrumentation"):
            performance.compare(instrumented, report())

    def test_instrumentation_requires_complete_consistent_slice_evidence(self):
        mutations = [lambda value: value.update(schemaVersion=True),
                     lambda value: value.update(method="environment"),
                     lambda value: value.update(llvmProfileInstrumented=0),
                     lambda value: value.update(llvmProfileInstrumented=True),
                     lambda value: value.update(binaries=[]),
                     lambda value: value["binaries"].append(dict(value["binaries"][0])),
                     lambda value: value["binaries"][0].update(architecture="x86_64"),
                     lambda value: value["binaries"][0].update(path="other"),
                     lambda value: value["binaries"][0].update(llvmProfileSections=None),
                     lambda value: value["binaries"][0].update(llvmProfileSections=["__text"]),
                     lambda value: value["binaries"][0].update(llvmProfileSections=["__llvm_prf_cnts"]),
                     lambda value: value["binaries"][0].update(llvmProfileSections=[[], []])]
        for mutate in mutations:
            candidate = report()
            mutate(candidate["buildInstrumentation"])
            with self.subTest(mutation=mutate), self.assertRaisesRegex(ValueError, "buildInstrumentation"):
                performance.compare(report(), candidate)
        candidate = report()
        candidate["artifactIdentity"]["machoUUIDs"]["Contents/MacOS/Keystorm"].append(
            {"architecture": "x86_64", "uuid": "11234567-89AB-CDEF-0123-456789ABCDEF"})
        with self.assertRaisesRegex(ValueError, "missing binary/architecture"):
            performance.compare(report(), candidate)

    def test_qualification_requires_fresh_timestamp_with_timezone(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        for generated in (None, "", "not-a-date", now.replace(tzinfo=None).isoformat(),
                          (now - datetime.timedelta(days=8)).isoformat(),
                          (now + datetime.timedelta(hours=1)).isoformat()):
            candidate = report()
            candidate["generatedAt"] = generated
            with self.subTest(timestamp=generated), self.assertRaisesRegex(ValueError, "generatedAt"):
                performance.compare(report(), candidate, qualify=True)

    def test_qualification_requires_valid_artifact_identity(self):
        mutations = [lambda value: value.pop("artifactIdentity"),
                     lambda value: value["artifactIdentity"].update(machoUUIDs={}),
                     lambda value: value["artifactIdentity"].update(mainExecutable="../Keystorm"),
                     lambda value: value["artifactIdentity"].update(buildNumber=""),
                     lambda value: value["artifactIdentity"]["machoUUIDs"]["Contents/MacOS/Keystorm"][0].update(uuid="bad")]
        for mutate in mutations:
            candidate = report()
            mutate(candidate)
            with self.assertRaisesRegex(ValueError, "artifactIdentity"):
                performance.compare(report(), candidate, qualify=True)

    def test_explicit_native_qualification_failure_cannot_be_overridden(self):
        for metadata in ({"qualificationFailures": ["additional native invariant failed"]},
                         {"qualificationRequested": True, "qualified": False}):
            candidate = dict(report(), **metadata)
            self.assertFalse(performance.compare(report(), candidate, qualify=True)["qualified"])

    def test_baseline_age_and_build_identity_need_not_match_candidate(self):
        baseline = report()
        baseline["generatedAt"] = "2025-01-01T00:00:00Z"
        baseline["artifactIdentity"]["buildNumber"] = "older-build"
        self.assertTrue(performance.compare(baseline, report(), qualify=True)["qualified"])

    def test_matching_release_runs_qualify_with_original_budgets(self):
        result = performance.compare(report(), report(), qualify=True)
        self.assertTrue(result["qualified"])
        self.assertEqual([item["budgetMilliseconds"] for item in result["fixedBudgets"]], [800, 700, 1500, 100])

    def test_baseline_can_miss_budgets_but_qualification_cannot(self):
        baseline = report(clean=2200)
        self.assertTrue(performance.compare(baseline, baseline)["passed"])
        self.assertFalse(performance.compare(baseline, baseline)["qualified"])
        self.assertFalse(performance.compare(baseline, baseline, qualify=True)["passed"])

    def test_thirty_pass_baseline_is_not_a_hundred_pass_qualification(self):
        baseline = report(count=30)
        self.assertTrue(performance.compare(baseline, baseline)["passed"])
        result = performance.compare(baseline, baseline, qualify=True)
        self.assertFalse(result["qualified"])
        self.assertIn("Qualification requires at least 100 warm samples", result["conditionFailures"])

    def test_report_cannot_weaken_the_fixed_budget(self):
        baseline = report(clean=2200)
        baseline["budgets"] = [{"budgetMilliseconds": 99999, "met": True}]
        self.assertFalse(performance.compare(baseline, baseline, qualify=True)["passed"])

    def test_material_warm_regression_fails_comparison_even_below_absolute_budget(self):
        candidate = report()
        for sample in candidate["passes"]:
            sample["rawMilliseconds"] = 250
        result = performance.compare(report(), candidate)
        self.assertFalse(result["passed"])
        self.assertTrue(any(item["regressed"] and item["metric"] == "raw" for item in result["comparisons"]))

    def test_small_difference_inside_noise_floor_does_not_regress(self):
        candidate = report()
        for sample in candidate["passes"]:
            sample["rawMilliseconds"] = 180
        self.assertTrue(performance.compare(report(), candidate)["passed"])

    def test_cold_outlier_is_separate_and_diagnostic(self):
        candidate = report()
        candidate["passes"][0]["rawMilliseconds"] = 20000
        result = performance.compare(report(), candidate)
        self.assertTrue(result["passed"])
        cold = [item for item in result["comparisons"] if item["scenario"] == "cold" and item["metric"] == "raw"]
        self.assertTrue(all(item["candidateMilliseconds"] == 20000 and not item["gated"] for item in cold))

    def test_changed_machine_model_fixture_or_build_is_incomparable(self):
        for key in ("hardwareModel", "speechModelRevision", "buildConfiguration", "operatingSystem"):
            with self.subTest(key=key):
                candidate = report()
                candidate[key] = "different"
                with self.assertRaises(ValueError):
                    performance.compare(report(), candidate)
        candidate = report()
        candidate["fixture"]["sha256"] = "other-audio"
        with self.assertRaises(ValueError):
            performance.compare(report(), candidate)

    def test_missing_models_failed_pass_or_partial_run_never_passes(self):
        mutations = [
            lambda value: value.update(textModelInstalled=False),
            lambda value: value.update(hostWorkspaceInitialized=True),
            lambda value: value["passes"][3].update(failure="worker timeout"),
            lambda value: value["passes"][3].update(insertedExactlyOnce=False),
            lambda value: value["passes"].pop(),
            lambda value: value["passes"][3].update(index=2),
        ]
        for mutate in mutations:
            candidate = report()
            mutate(candidate)
            with self.assertRaises(ValueError):
                performance.compare(report(), candidate)
        with self.assertRaises(ValueError):
            performance.compare(report(count=2), report(count=2))

    def test_fixture_feed_pacing_must_match_with_legacy_twelve_ms_default(self):
        legacy = report()
        explicit_legacy = dict(report(), fixtureFeedPauseMilliseconds=12)
        self.assertTrue(performance.compare(legacy, explicit_legacy)["passed"])
        accelerated = dict(report(), fixtureFeedPauseMilliseconds=2)
        self.assertEqual(performance.compare(accelerated, accelerated)["fixtureFeedPauseMilliseconds"], 2)
        with self.assertRaisesRegex(ValueError, "fixtureFeedPauseMilliseconds"):
            performance.compare(legacy, accelerated)

    def test_fixture_feed_pacing_requires_a_positive_finite_number(self):
        for value in (0, -1, float("nan"), float("inf"), True, None, "2"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "fixtureFeedPauseMilliseconds"):
                performance.compare(report(), dict(report(), fixtureFeedPauseMilliseconds=value))

    def test_invalid_or_missing_timing_is_rejected(self):
        for invalid in (float("nan"), float("inf"), -1, True, None, "5"):
            candidate = report()
            candidate["passes"][3]["rawMilliseconds"] = invalid
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                performance.compare(report(), candidate)

    def test_thermal_or_power_conditions_prevent_qualification(self):
        candidate = report()
        candidate["thermalStateAtEnd"] = 2
        self.assertFalse(performance.compare(report(), candidate, qualify=True)["passed"])
        low_power = report()
        low_power["lowPowerMode"] = True
        self.assertFalse(performance.compare(low_power, low_power, qualify=True)["passed"])
        fair = report()
        fair["thermalStateAtEnd"] = 1
        self.assertTrue(performance.compare(report(), fair, qualify=True)["passed"])
        fair["thermalStateAtStart"] = 1
        with self.assertRaises(ValueError):
            performance.compare(report(), fair)

    def test_reported_warm_resources_must_confirm_worker_and_model_residency(self):
        baseline = report()
        baseline["resourceSnapshots"] = []
        for sample in baseline["passes"]:
            sample["resourcesAfterPass"] = {"workerPID": 42, "speechModelLoaded": 1,
                                           "textModelLoaded": 1, "speechModelLoads": 1, "textModelLoads": 1}
        self.assertTrue(performance.compare(baseline, baseline)["passed"])
        for key, changed in (("workerPID", 43), ("speechModelLoaded", 0), ("textModelLoads", 2)):
            last = baseline["passes"][-1]["resourcesAfterPass"]
            original = last[key]
            last[key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError):
                performance.compare(baseline, baseline)
            last[key] = original

    def test_unrelated_or_malformed_report_scope_is_rejected(self):
        for candidate in ([], {}, dict(report(), fixture="bad"), dict(report(), benchmarkKind="coordinator")):
            with self.subTest(value=type(candidate)), self.assertRaises(ValueError):
                performance.compare(report(), candidate)

    def test_output_cannot_overwrite_original_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "baseline.json"
            original.write_text("original evidence")
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                performance.main(["--baseline", str(original), "--candidate", str(original),
                                  "--output", str(original)])
            self.assertEqual(failure.exception.code, 2)
            self.assertEqual(original.read_text(), "original evidence")


if __name__ == "__main__":
    unittest.main()
