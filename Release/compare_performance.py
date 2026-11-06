#!/usr/bin/env python3
"""Compare matching Release Finish latency reports without changing their budgets.

Usage: python3 -I Release/compare_performance.py --baseline baseline.json
           --candidate candidate.json --output comparison.json [--qualify]

Baseline collection is allowed to miss a target. --qualify additionally enforces
the fixed engineering budgets. Cold and prewarmed-first samples remain separate
diagnostics; one sample cannot establish a cold-start percentile guarantee.
"""
import argparse
import datetime
import json
import math
from pathlib import Path, PurePosixPath
import re
import sys
import uuid

MINIMUM_WARM_SAMPLES = 30
QUALIFICATION_WARM_SAMPLES = 100
QUALIFICATION_MAX_AGE = datetime.timedelta(days=7)
MAX_CLOCK_SKEW = datetime.timedelta(minutes=5)
METRICS = {
    "raw": "rawMilliseconds",
    "clean": "cleanMilliseconds",
    "finishToClean": "finishToCleanMilliseconds",
    "delivery": "deliveryMilliseconds",
    "receiptSave": "receiptSaveMilliseconds",
}
# Same fixed targets as FinishLatencyHarness, not inferred from either input.
BUDGETS = (("raw", .95, 800), ("finishToClean", .50, 700),
           ("finishToClean", .95, 1500), ("delivery", .95, 100))
COMPATIBILITY_KEYS = ("hardwareModel", "physicalMemoryBytes", "operatingSystem",
                      "buildConfiguration", "speechModelID", "speechModelRevision",
                      "textModelID", "textModelRevision", "lowPowerMode", "thermalStateAtStart")
SCENARIOS = ("cold", "prewarmedFirst", "warm")


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("Cannot calculate a percentile without samples")
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def fixture_feed_pause(report):
    # Schema 1 reports written before this field used the original 12 ms feed.
    value = report.get("fixtureFeedPauseMilliseconds", 12)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValueError("Invalid fixtureFeedPauseMilliseconds: a positive finite number is required")
    return value


def artifact_identity(value):
    """Validate and normalize the candidate's executable identity, excluding signatures.

    Mach-O UUIDs survive re-signing. Preflight compares every shipped executable
    slice with this identity rather than accepting a report from another build.
    """
    prefix = "artifactIdentity: "
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise ValueError(prefix + "schemaVersion 1 is required")
    for key in ("bundleIdentifier", "marketingVersion", "buildNumber", "mainExecutable"):
        if not isinstance(value.get(key), str) or not value[key].strip():
            raise ValueError(prefix + "missing " + key)

    def relative_path(path):
        if not isinstance(path, str) or not path or "\\" in path:
            return False
        parsed = PurePosixPath(path)
        return bool(parsed.parts) and not parsed.is_absolute() and ".." not in parsed.parts and str(parsed) == path

    binaries = value.get("machoUUIDs")
    if not isinstance(binaries, dict) or not binaries or value["mainExecutable"] not in binaries:
        raise ValueError(prefix + "machoUUIDs must include the main executable")
    normalized = {}
    for path, slices in binaries.items():
        if not relative_path(path) or not isinstance(slices, list) or not slices:
            raise ValueError(prefix + "invalid binary path or empty UUID slices")
        architectures = set()
        normalized[path] = []
        for item in slices:
            if not isinstance(item, dict):
                raise ValueError(prefix + "invalid UUID slice")
            architecture, identifier = item.get("architecture"), item.get("uuid")
            if not isinstance(architecture, str) or not re.fullmatch(r"[A-Za-z0-9_]+", architecture) or architecture in architectures:
                raise ValueError(prefix + "missing or duplicate architecture")
            if not isinstance(identifier, str) or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identifier):
                raise ValueError(prefix + "invalid Mach-O UUID")
            architectures.add(architecture)
            normalized[path].append({"architecture": architecture, "uuid": str(uuid.UUID(identifier)).upper()})
        normalized[path].sort(key=lambda item: (item["architecture"], item["uuid"]))
    return {"schemaVersion": 1, **{key: value[key] for key in (
        "bundleIdentifier", "marketingVersion", "buildNumber", "mainExecutable")}, "machoUUIDs": normalized}


INSTRUMENTATION_METHOD = "mach-o-llvm-profile-sections-v1"


def build_instrumentation(value, identity):
    """Require exhaustive per-slice evidence; absence of evidence is not 'off'."""
    identity = artifact_identity(identity)
    prefix = "buildInstrumentation: "
    if (not isinstance(value, dict) or type(value.get("schemaVersion")) is not int
            or value["schemaVersion"] != 1 or value.get("method") != INSTRUMENTATION_METHOD):
        raise ValueError(prefix + "verified Mach-O section inspection is required")
    expected = {(path, item["architecture"]) for path, slices in identity["machoUUIDs"].items() for item in slices}
    records = value.get("binaries")
    if not isinstance(records, list) or not records:
        raise ValueError(prefix + "complete binary/architecture coverage is required")
    seen, normalized = set(), []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError(prefix + "invalid binary record")
        path, architecture = record.get("path"), record.get("architecture")
        if not isinstance(path, str) or not isinstance(architecture, str):
            raise ValueError(prefix + "invalid binary path/architecture")
        key = (path, architecture)
        if key in seen or key not in expected:
            raise ValueError(prefix + "duplicate or unexpected binary/architecture")
        seen.add(key)
        sections = record.get("llvmProfileSections")
        if (not isinstance(sections, list)
                or any(not isinstance(section, str) or not re.fullmatch(r"__llvm_(?:prf_[A-Za-z0-9_]+|cov[A-Za-z0-9_]*)", section)
                       for section in sections) or len(sections) != len(set(sections))):
            raise ValueError(prefix + "invalid LLVM section evidence")
        normalized.append({"path": path, "architecture": architecture, "llvmProfileSections": sorted(sections)})
    if seen != expected:
        raise ValueError(prefix + "missing binary/architecture evidence")
    instrumented = any(record["llvmProfileSections"] for record in normalized)
    if type(value.get("llvmProfileInstrumented")) is not bool or value["llvmProfileInstrumented"] != instrumented:
        raise ValueError(prefix + "instrumented flag contradicts section evidence")
    return {"schemaVersion": 1, "method": INSTRUMENTATION_METHOD,
            "binaries": sorted(normalized, key=lambda item: (item["path"], item["architecture"])),
            "llvmProfileInstrumented": instrumented}


def check_freshness(report, now=None):
    generated = report.get("generatedAt")
    try:
        if not isinstance(generated, str):
            raise ValueError()
        timestamp = datetime.datetime.fromisoformat(generated.replace("Z", "+00:00"))
        if timestamp.tzinfo is None:
            raise ValueError()
    except ValueError:
        raise ValueError("candidate: generatedAt must be an ISO 8601 timestamp with a timezone") from None
    age = (now or datetime.datetime.now(datetime.timezone.utc)) - timestamp
    if age < -MAX_CLOCK_SKEW or age > QUALIFICATION_MAX_AGE:
        raise ValueError("candidate: generatedAt must be within the last 7 days (at most 5 minutes clock skew)")


def positive_integer(value):
    return type(value) is int and value > 0


def checked_report(report, label, qualification=False, now=None):
    if not isinstance(report, dict):
        raise ValueError(label + ": expected a report object")
    if report.get("schemaVersion") != 1 or report.get("benchmarkKind", "finish-components-v1") != "finish-components-v1":
        raise ValueError(label + ": unsupported benchmark schema or measurement scope")
    fixture_feed_pause(report)
    instrumentation = build_instrumentation(report.get("buildInstrumentation"), report.get("artifactIdentity"))
    if qualification and instrumentation["llvmProfileInstrumented"]:
        raise ValueError(label + ": LLVM profile/coverage instrumentation must be absent for qualification")
    if report.get("buildConfiguration") != "Release":
        raise ValueError(label + ": a true Release report is required")
    if report.get("hostWorkspaceInitialized") is True:
        raise ValueError(label + ": hosted app workspace contaminated the benchmark")
    if qualification:
        if report.get("hostWorkspaceInitialized") is not False:
            raise ValueError(label + ": hostWorkspaceInitialized must explicitly be false")
        check_freshness(report, now)
        artifact_identity(report.get("artifactIdentity"))
    if report.get("textModelInstalled") is not True:
        raise ValueError(label + ": both installed models are required; Clean was not measured")
    for key in COMPATIBILITY_KEYS:
        if report.get(key) is None:
            raise ValueError(label + ": missing provenance field " + key)
    if not isinstance(report.get("fixture"), dict) or not report["fixture"].get("sha256"):
        raise ValueError(label + ": missing fixture hash")
    passes = report.get("passes")
    if not isinstance(passes, list) or not passes:
        raise ValueError(label + ": no passes were recorded")
    grouped = {scenario: [] for scenario in SCENARIOS}
    indices = set()
    for sample in passes:
        if not isinstance(sample, dict):
            raise ValueError(label + ": invalid pass")
        index = sample.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or index in indices:
            raise ValueError(label + ": missing or duplicate pass index")
        indices.add(index)
        if sample.get("failure") or sample.get("insertedExactlyOnce") is not True:
            raise ValueError(label + ": failed/incomplete pass " + str(index))
        scenario = sample.get("scenario")
        if scenario not in grouped:
            raise ValueError(label + ": unknown pass scenario")
        for key in METRICS.values():
            value = sample.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError(label + ": invalid/missing timing " + key)
        grouped[scenario].append(sample)
    requested = report.get("requestedWarmPasses")
    if len(grouped["warm"]) != requested or len(grouped["warm"]) < MINIMUM_WARM_SAMPLES:
        raise ValueError(label + ": at least 30 complete warm passes and the requested count are required")
    if not grouped["cold"] or not grouped["prewarmedFirst"]:
        raise ValueError(label + ": cold and prewarmed-first evidence must remain separate")
    if qualification or "resourceSnapshots" in report or any("resourcesAfterPass" in sample for sample in grouped["warm"]):
        warm_resources = [sample.get("resourcesAfterPass", {}) for sample in grouped["warm"]]
        if any(not isinstance(sample, dict) for sample in warm_resources):
            raise ValueError(label + ": invalid warm resource evidence")
        if any(not positive_integer(sample.get("workerPID")) for sample in warm_resources):
            raise ValueError(label + ": warm passes require a positive workerPID")
        worker_ids = {sample.get("workerPID") for sample in warm_resources}
        if len(worker_ids) != 1:
            raise ValueError(label + ": warm passes did not keep one resident worker")
        for key in ("speechModelLoaded", "textModelLoaded"):
            if any(type(sample.get(key)) is not int or sample[key] != 1 for sample in warm_resources):
                raise ValueError(label + ": warm model residency was not established: " + key)
        for key in ("speechModelLoads", "textModelLoads"):
            if any(not positive_integer(sample.get(key)) for sample in warm_resources):
                raise ValueError(label + ": missing/invalid warm model-load counter: " + key)
            counts = {sample[key] for sample in warm_resources}
            if len(counts) != 1:
                raise ValueError(label + ": a model reloaded during warm measurement: " + key)
    return grouped


def compare(baseline, candidate, qualify=False, now=None):
    before = checked_report(baseline, "baseline")
    after = checked_report(candidate, "candidate", qualification=qualify, now=now)
    mismatches = [key for key in COMPATIBILITY_KEYS if baseline[key] != candidate[key]]
    before_instrumentation = build_instrumentation(baseline.get("buildInstrumentation"), baseline.get("artifactIdentity"))
    after_instrumentation = build_instrumentation(candidate.get("buildInstrumentation"), candidate.get("artifactIdentity"))
    # Build UUIDs may differ, but all matching shipped slices must have identical instrumentation.
    if before_instrumentation != after_instrumentation:
        mismatches.append("buildInstrumentation")
    if baseline["fixture"]["sha256"] != candidate["fixture"]["sha256"]:
        mismatches.append("fixture.sha256")
    if fixture_feed_pause(baseline) != fixture_feed_pause(candidate):
        mismatches.append("fixtureFeedPauseMilliseconds")
    if mismatches:
        raise ValueError("Incomparable runs: " + ", ".join(mismatches))
    comparisons = []
    for scenario in SCENARIOS:
        for metric, key in METRICS.items():
            old = [sample[key] for sample in before[scenario]]
            new = [sample[key] for sample in after[scenario]]
            for fraction in (.50, .95):
                old_value, new_value = percentile(old, fraction), percentile(new, fraction)
                # A fixed floor, 10% relative allowance, and twice baseline IQR.
                # Candidate variance never expands its own permitted regression.
                absolute = 5 if metric in ("delivery", "receiptSave") else 50
                noise = 2 * (percentile(old, .75) - percentile(old, .25))
                allowance = max(absolute, old_value * .10, noise)
                measured_regression = new_value - old_value > allowance
                comparisons.append({
                    "scenario": scenario, "metric": metric,
                    "percentile": "p" + str(round(fraction * 100)),
                    "baselineMilliseconds": old_value, "candidateMilliseconds": new_value,
                    "deltaMilliseconds": new_value - old_value,
                    "allowedRegressionMilliseconds": allowance,
                    "baselineSamples": len(old), "candidateSamples": len(new),
                    "gated": scenario == "warm",
                    "regressed": measured_regression if scenario == "warm" else None,
                })
    budgets = []
    for metric, fraction, maximum in BUDGETS:
        value = percentile([sample[METRICS[metric]] for sample in after["warm"]], fraction)
        budgets.append({"metric": metric, "percentile": "p" + str(round(fraction * 100)),
                        "observedMilliseconds": value, "budgetMilliseconds": maximum,
                        "met": value <= maximum})
    condition_failures = []
    if qualify:
        if candidate.get("qualificationFailures"):
            condition_failures.append("The native benchmark reported qualification failures: "
                                      + str(candidate["qualificationFailures"]))
        if candidate.get("qualificationRequested") is True and candidate.get("qualified") is not True:
            condition_failures.append("The native benchmark's requested qualification did not pass")
        if len(after["warm"]) < QUALIFICATION_WARM_SAMPLES:
            condition_failures.append("Qualification requires at least 100 warm samples")
        if candidate["lowPowerMode"] is not False:
            condition_failures.append("Low Power Mode must explicitly be off")
        if any(type(candidate.get(key)) is not int or candidate[key] not in (0, 1)
               for key in ("thermalStateAtStart", "thermalStateAtEnd")):
            condition_failures.append("Thermal state must be nominal or fair, not serious or critical")
    regressions = [item for item in comparisons if item["regressed"]]
    passed = not regressions and (not qualify or (all(item["met"] for item in budgets) and not condition_failures))
    return {"schemaVersion": 1, "mode": "qualification" if qualify else "baseline-comparison",
            "passed": passed, "qualified": qualify and passed,
            "fixtureFeedPauseMilliseconds": fixture_feed_pause(candidate),
            "buildInstrumentation": after_instrumentation,
            "comparisons": comparisons, "fixedBudgets": budgets,
            "conditionFailures": condition_failures,
            "thermalConditions": {
                "baselineStart": baseline.get("thermalStateAtStart"), "baselineEnd": baseline.get("thermalStateAtEnd"),
                "candidateStart": candidate.get("thermalStateAtStart"), "candidateEnd": candidate.get("thermalStateAtEnd")},
            "limits": "Component Finish path only. No physical shortcut, microphone, capture drain, HUD paint, real Accessibility delivery, or sustained energy qualification. Cold/prewarmed-first values are diagnostic, not percentile gates."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qualify", action="store_true")
    args = parser.parse_args(argv)
    if args.output.resolve() in (args.baseline.resolve(), args.candidate.resolve()):
        parser.error("--output must not overwrite either source report")
    try:
        result = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()), args.qualify)
        status = 0 if result["passed"] else 1
    except (OSError, ValueError, TypeError, KeyError) as error:
        result = {"schemaVersion": 1, "passed": False, "qualified": False, "error": str(error)}
        status = 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(json.dumps({"passed": result["passed"], "qualified": result["qualified"],
                      "report": str(args.output), "error": result.get("error")}, sort_keys=True))
    return status


if __name__ == "__main__":
    sys.exit(main())
