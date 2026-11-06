#!/usr/bin/env python3
"""Offline unit tests for the Release/ scripts. They use synthetic bundles and canned
tool output only: no codesign, otool, real app, process sampling or network.

Usage: python3 -I Release/test_release_tools.py
"""
import importlib.util
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location("keystorm_release_" + name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


audit = load("audit_signatures")
preflight = load("preflight")
soak = load("soak")
performance_fixture = load("test_compare_performance").report

TEAM = "84PD63F63N"
DEV_CN = "Apple Development: Example Person (AB12CD34EF)"
DEV_REQUIREMENT = ('identifier "dev.mitternacht.Keystorm" and anchor apple generic and '
                   'certificate leaf[subject.CN] = 0x%s and certificate 1[field.1.2.840.113635.100.6.2.1] '
                   '/* exists */' % DEV_CN.encode().hex())
DEVID_REQUIREMENT = ('identifier "dev.mitternacht.Keystorm" and anchor apple generic and '
                     'certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and '
                     'certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and '
                     'certificate leaf[subject.OU] = "%s"' % TEAM)


def thin_header(cputype=0x0100000C, cpusubtype=0, filetype=2):
    return struct.pack("<IiiI", 0xFEEDFACF, cputype, cpusubtype, filetype) + b"\0" * 16


def fat_binary(filetype):
    slices = [(0x0100000C, 0, 4096), (0x01000007, 3, 8192)]
    data = bytearray(8192 + 32)
    data[0:8] = struct.pack(">II", 0xCAFEBABE, len(slices))
    for index, (cputype, subtype, offset) in enumerate(slices):
        data[8 + index * 20:8 + (index + 1) * 20] = struct.pack(">iiIII", cputype, subtype, offset, 32, 12)
        data[offset:offset + 32] = thin_header(cputype, subtype, filetype)
    return bytes(data)


def display(identifier, team=TEAM, flags="0x10000(runtime)", authority=DEV_CN, timestamp=None):
    lines = ["Executable=/x", "Identifier=%s" % identifier, "Format=app bundle with Mach-O thin (arm64)",
             "CodeDirectory v=20500 size=453 flags=%s hashes=3+7 location=embedded" % flags,
             "CDHash=abc123", "Authority=%s" % authority,
             "Authority=Apple Worldwide Developer Relations Certification Authority",
             "Authority=Apple Root CA"]
    lines.append("Timestamp=%s" % timestamp if timestamp else "Signed Time=20 Oct 2026 at 14:51:21")
    lines.append("TeamIdentifier=%s" % (team or "not set"))
    return "\n".join(lines)


class FakeRunner:
    """Serves canned codesign output per target path."""

    def __init__(self, signatures, verify_failures=(), bundle_failure=False):
        self.signatures = signatures
        self.verify_failures = set(verify_failures)
        self.bundle_failure = bundle_failure
        self.calls = []

    def __call__(self, arguments, timeout=60):
        self.calls.append(arguments)
        target = Path(arguments[-1]).name
        entry = self.signatures.get(target)
        if "--verify" in arguments:
            # The audit verifies the whole bundle with "--verify --deep" and each item with "--verify --strict".
            failed = self.bundle_failure if arguments[2] == "--deep" else target in self.verify_failures
            return {"code": 1 if failed else 0, "stdout": b"",
                    "stderr": b"invalid signature" if failed else b"valid on disk"}
        if entry is None:
            return {"code": 1, "stdout": b"", "stderr": b"/x: code object is not signed at all"}
        if "-r-" in arguments:
            return {"code": 0, "stdout": ("designated => %s\n" % entry["requirement"]).encode(), "stderr": b""}
        if "--entitlements" in arguments:
            data = plistlib.dumps(entry["entitlements"]) if entry["entitlements"] else b""
            return {"code": 0, "stdout": data, "stderr": b"Executable=/x"}
        return {"code": 0, "stdout": b"", "stderr": entry["display"].encode()}


def make_app(root, extra=None):
    """Create a synthetic Keystorm.app; returns its path."""
    app = Path(root) / "Keystorm.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "Keystorm", "CFBundleIdentifier": "dev.mitternacht.Keystorm"}))
    (app / "Contents" / "MacOS" / "Keystorm").write_bytes(thin_header(filetype=2))
    resources = app / "Contents" / "Resources" / "mlx-swift_Cmlx.bundle" / "Contents"
    resources.mkdir(parents=True)
    (resources / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "mlx"}))
    for build in (extra or ()):
        build(app)
    return app


def add_framework(app):
    framework = app / "Contents" / "Frameworks" / "Foo.framework"
    (framework / "Versions" / "A" / "Resources").mkdir(parents=True)
    (framework / "Versions" / "A" / "Foo").write_bytes(fat_binary(6))
    (framework / "Versions" / "A" / "Resources" / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleExecutable": "Foo"}))
    os.symlink("A", framework / "Versions" / "Current")
    os.symlink("Versions/Current/Foo", framework / "Foo")
    os.symlink("Versions/Current/Resources", framework / "Resources")


def add_worker_service(app):
    service = app / "Contents" / "XPCServices" / "Worker.xpc" / "Contents"
    (service / "MacOS").mkdir(parents=True)
    (service / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Worker"}))
    (service / "MacOS" / "Worker").write_bytes(thin_header(filetype=2))


def add_loose_dylib(app):
    (app / "Contents" / "MacOS" / "Keystorm.debug.dylib").write_bytes(thin_header(filetype=6))


class MachOTests(unittest.TestCase):
    def test_thin_fat_and_non_macho(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "thin").write_bytes(thin_header(filetype=2))
            (folder / "fat").write_bytes(fat_binary(6))
            (folder / "arm64e").write_bytes(thin_header(cpusubtype=2, filetype=8))
            (folder / "java").write_bytes(struct.pack(">IHH", 0xCAFEBABE, 0, 52) + b"\0" * 32)
            (folder / "archive").write_bytes(b"!<arch>\n" + b"\0" * 32)
            (folder / "text").write_bytes(b"hello world, not code")
            self.assertEqual(audit.macho_info(folder / "thin"), {"filetype": "execute", "architectures": ["arm64"]})
            self.assertEqual(audit.macho_info(folder / "fat"),
                             {"filetype": "dylib", "architectures": ["arm64", "x86_64"]})
            self.assertEqual(audit.macho_info(folder / "arm64e")["architectures"], ["arm64e"])
            self.assertIsNone(audit.macho_info(folder / "java"))
            self.assertEqual(audit.macho_info(folder / "archive")["filetype"], "static-archive")
            self.assertIsNone(audit.macho_info(folder / "text"))


class DiscoveryTests(unittest.TestCase):
    def test_walks_nested_code_and_skips_resource_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(directory, (add_framework, add_worker_service, add_loose_dylib))
            os.symlink("/etc/hosts", app / "Contents" / "Resources" / "escape")
            items, resources, problems = audit.discover(Path(os.path.realpath(app)))
            kinds = {item["relative"]: item["kind"] for item in items}
            self.assertEqual(kinds, {
                ".": "app",
                "Contents/Frameworks/Foo.framework": "framework",
                "Contents/MacOS/Keystorm.debug.dylib": "dylib",
                "Contents/XPCServices/Worker.xpc": "xpc-service",
            })
            framework = next(item for item in items if item["kind"] == "framework")
            self.assertEqual(framework["executable_relative"], "Contents/Frameworks/Foo.framework/Versions/A/Foo")
            self.assertEqual(resources, ["Contents/Resources/mlx-swift_Cmlx.bundle"])
            self.assertEqual([problem["check"] for problem in problems], ["symlink_escapes_bundle"])


class RequirementTests(unittest.TestCase):
    def test_classification(self):
        self.assertEqual(audit.classify_requirement(DEVID_REQUIREMENT), {"anchor": "team", "team": TEAM})
        self.assertEqual(audit.classify_requirement(DEV_REQUIREMENT), {"anchor": "certificate", "common_name": DEV_CN})
        self.assertEqual(audit.classify_requirement('cdhash H"0123abcd"')["anchor"], "cdhash-only")
        self.assertEqual(audit.classify_requirement('identifier "x" and anchor apple generic')["anchor"],
                         "apple-generic-only")
        self.assertEqual(audit.classify_requirement(None)["anchor"], "missing")

    def test_parse_requirement_marks_implicit(self):
        self.assertEqual(audit.parse_requirement('Executable=/x\n# designated => cdhash H"ab"'), ('cdhash H"ab"', True))
        self.assertEqual(audit.parse_requirement("designated => " + DEV_REQUIREMENT), (DEV_REQUIREMENT, False))

    def test_parse_display(self):
        fields = audit.parse_display(display("dev.mitternacht.Keystorm", timestamp="20 Oct 2026 at 15:00:00"))
        self.assertEqual(fields["team_identifier"], TEAM)
        self.assertEqual(fields["flags"], 0x10000)
        self.assertEqual(fields["timestamp"], "20 Oct 2026 at 15:00:00")
        self.assertIsNone(fields["signed_time"])
        unsigned = audit.parse_display("/x: code object is not signed at all")
        self.assertFalse(unsigned["signed"])
        adhoc = audit.parse_display(display("x", team=None, flags="0x20002(adhoc,linker-signed)"))
        self.assertIsNone(adhoc["team_identifier"])


def signature(identifier, requirement=DEV_REQUIREMENT, entitlements=None, **kwargs):
    return {"display": display(identifier, **kwargs), "requirement": requirement.replace(
        "dev.mitternacht.Keystorm", identifier), "entitlements": entitlements or {}}


class AuditTests(unittest.TestCase):
    def run_audit(self, signatures, extra=(), **kwargs):
        runner = kwargs.pop("runner", None) or FakeRunner(signatures)
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(directory, extra)
            report = audit.audit(app, runner=runner, **kwargs)
        return report, {(finding["check"], finding["path"], finding["severity"]) for finding in report["findings"]}

    def test_development_release_build_passes_with_warnings(self):
        signatures = {"Keystorm.app": signature("dev.mitternacht.Keystorm",
                                                 entitlements={"com.apple.security.device.audio-input": True})}
        report, findings = self.run_audit(signatures)
        self.assertTrue(report["passed"])
        self.assertIn(("secure_timestamp", ".", "warning"), findings)
        self.assertIn(("designated_requirement", ".", "warning"), findings)
        self.assertIn(("signing_identity", ".", "warning"), findings)
        self.assertEqual(report["items"][0]["entitlements"], {"com.apple.security.device.audio-input": True})
        self.assertTrue(any("inference worker" in note for note in report["notes"]))

    def test_distribution_requires_timestamp_team_requirement_and_developer_id(self):
        signatures = {"Keystorm.app": signature("dev.mitternacht.Keystorm")}
        report, findings = self.run_audit(signatures, distribution=True)
        self.assertFalse(report["passed"])
        for check in ("secure_timestamp", "designated_requirement", "developer_id_authority"):
            self.assertIn((check, ".", "failure"), findings)
        good = {"Keystorm.app": signature("dev.mitternacht.Keystorm", requirement=DEVID_REQUIREMENT,
                                           authority="Developer ID Application: Example (%s)" % TEAM,
                                           timestamp="20 Oct 2026 at 15:00:00")}
        report, _ = self.run_audit(good, distribution=True)
        self.assertTrue(report["passed"], report["findings"])

    def test_get_task_allow_fails_release_and_warns_debug(self):
        signatures = {"Keystorm.app": signature("dev.mitternacht.Keystorm",
                                                 entitlements={audit.GET_TASK_ALLOW: True})}
        _, findings = self.run_audit(signatures)
        self.assertIn(("get_task_allow", ".", "failure"), findings)
        report, findings = self.run_audit(signatures, configuration="debug")
        self.assertIn(("get_task_allow", ".", "warning"), findings)
        self.assertTrue(report["passed"])

    def test_nested_items_need_team_runtime_and_signature(self):
        signatures = {
            "Keystorm.app": signature("dev.mitternacht.Keystorm"),
            # Executable without the runtime flag and a different team.
            "Worker.xpc": signature("dev.mitternacht.Keystorm.Worker", team="ZZZZZZZZZZ", flags="0x0(none)"),
            # Dylibs need no runtime flag; this one is debug-only.
            "Keystorm.debug.dylib": signature("Keystorm.debug", flags="0x0(none)"),
            # Foo.framework is unsigned.
        }
        report, findings = self.run_audit(signatures, extra=(add_framework, add_worker_service, add_loose_dylib))
        self.assertFalse(report["passed"])
        self.assertIn(("hardened_runtime", "Contents/XPCServices/Worker.xpc", "failure"), findings)
        self.assertIn(("team_identifier", "Contents/XPCServices/Worker.xpc", "failure"), findings)
        self.assertIn(("single_team", ".", "failure"), findings)
        self.assertIn(("signed", "Contents/Frameworks/Foo.framework", "failure"), findings)
        self.assertIn(("debug_artifact", "Contents/MacOS/Keystorm.debug.dylib", "failure"), findings)
        self.assertNotIn(("hardened_runtime", "Contents/MacOS/Keystorm.debug.dylib", "failure"), findings)
        self.assertFalse(any("inference worker" in note for note in report["notes"]))

    def test_ad_hoc_cdhash_and_verification_failures(self):
        signatures = {"Keystorm.app": signature("dev.mitternacht.Keystorm", team=None,
                                                 flags="0x10002(adhoc,runtime)",
                                                 requirement='cdhash H"0123"')}
        runner = FakeRunner(signatures, verify_failures={"Keystorm.app"}, bundle_failure=True)
        report, findings = self.run_audit(signatures, runner=runner)
        for check in ("ad_hoc_signature", "team_identifier", "designated_requirement",
                      "verify_strict_deep", "bundle_verify_strict_deep"):
            self.assertIn(check, {finding[0] for finding in findings if finding[2] == "failure"})
        self.assertFalse(report["passed"])

    def test_missing_main_executable_fails(self):
        def remove_executable(app):
            (app / "Contents" / "MacOS" / "Keystorm").unlink()

        signatures = {"Keystorm.app": signature("dev.mitternacht.Keystorm")}
        report, findings = self.run_audit(signatures, extra=(remove_executable,))
        self.assertIn(("main_executable", ".", "failure"), findings)
        self.assertFalse(report["passed"])

    def test_runner_is_only_ever_codesign_and_render_works(self):
        signatures = {"Keystorm.app": signature("dev.mitternacht.Keystorm")}
        runner = FakeRunner(signatures)
        report, _ = self.run_audit(signatures, runner=runner)
        self.assertTrue(all(call[0] == "/usr/bin/codesign" for call in runner.calls))
        self.assertFalse(any(flag in call for call in runner.calls for flag in ("--sign", "-s", "--force", "--remove-signature")))
        table = audit.render(report)
        self.assertIn("Keystorm.app", table)
        self.assertIn("Result: PASS", table)


def otool_fixture(identifier, sections=("__text",), cputype=16777228, cpusubtype=0):
    segment_size = 72 + 80 * len(sections)
    lines = ["fixture:", "Mach header",
             "magic cputype cpusubtype caps filetype ncmds sizeofcmds flags",
             "0xfeedfacf %d %d 0x00 2 2 %d 0x00" % (cputype, cpusubtype, segment_size + 24),
             "Load command 0", "cmd LC_SEGMENT_64", "cmdsize " + str(segment_size),
             "nsects " + str(len(sections))]
    for section in sections:
        lines += ["Section", "sectname " + section]
    return "\n".join(lines + ["Load command 1", "cmd LC_UUID", "cmdsize 24", "uuid " + identifier]) + "\n"


class PerformancePreflightTests(unittest.TestCase):
    def make_artifact(self, directory):
        app = make_app(directory, [add_framework])
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        info.update(CFBundleShortVersionString="1.0", CFBundleVersion="1",
                    NSMicrophoneUsageDescription="Record dictation", LSMinimumSystemVersion="27.0")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        return app, info

    def uuid_runner(self, arguments, timeout=20, input_data=None):
        identifier = ("01234567-89AB-CDEF-0123-456789ABCDEF" if Path(arguments[-1]).name == "Keystorm"
                      else "11234567-89AB-CDEF-0123-456789ABCDEF")
        if "lipo" in arguments:
            self.assertEqual(arguments[:3], ["/usr/bin/xcrun", "lipo", "-archs"])
            return {"code": 0, "stdout": b"arm64\n", "stderr": b"", "oversized": False}
        if "otool" in arguments:
            self.assertEqual(arguments[:6], ["/usr/bin/xcrun", "otool", "-arch", "arm64", "-h", "-l"])
            return {"code": 0, "stdout": otool_fixture(identifier).encode(), "stderr": b"", "oversized": False}
        self.assertEqual(arguments[:3], ["/usr/bin/xcrun", "dwarfdump", "--uuid"])
        return {"code": 0, "stdout": ("UUID: %s (arm64) %s\n" % (identifier, arguments[-1])).encode(),
                "stderr": b"", "oversized": False}

    def write_reports(self, directory, app, info, mutate=None):
        baseline, candidate = performance_fixture(), performance_fixture()
        candidate["artifactIdentity"] = preflight.capture_artifact_identity(app, info, runner=self.uuid_runner)
        candidate["buildInstrumentation"] = preflight.capture_build_instrumentation(app, candidate["artifactIdentity"], runner=self.uuid_runner)
        baseline["artifactIdentity"] = candidate["artifactIdentity"]
        baseline["buildInstrumentation"] = candidate["buildInstrumentation"]
        if mutate:
            mutate(candidate)
        paths = Path(directory) / "baseline.json", Path(directory) / "candidate.json"
        for path, value in zip(paths, (baseline, candidate)):
            path.write_text(json.dumps(value))
        return paths

    def test_artifact_identity_covers_embedded_code_without_symlink_duplicates_or_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            for relative in ("Contents/PlugIns/Tests.xctest/Contents/MacOS/Tests",
                             "Contents/PlugIns/Tests.xctest.dSYM/Contents/Resources/DWARF/Tests",
                             "Contents/_CodeSignature/test", "Contents/.git/test"):
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(thin_header())
            identity = preflight.capture_artifact_identity(app, info, runner=self.uuid_runner)
            self.assertEqual(set(identity["machoUUIDs"]), {
                "Contents/MacOS/Keystorm", "Contents/Frameworks/Foo.framework/Versions/A/Foo"})
            self.assertEqual(identity["mainExecutable"], "Contents/MacOS/Keystorm")
            self.assertEqual(identity["buildNumber"], "1")

    def test_unreadable_or_uuidless_macho_cannot_be_omitted(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            for response in ({"code": 1, "stdout": b"", "stderr": b"broken", "oversized": False},
                             {"code": 0, "stdout": b"", "stderr": b"", "oversized": False}):
                with self.subTest(response=response), self.assertRaises(ValueError):
                    preflight.capture_artifact_identity(app, info, runner=lambda *args, **kwargs: response)

    def test_architecture_inventory_cannot_omit_uuidless_fat_slices(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            for mode in ("missing-slice", "duplicate-uuid", "duplicate-arch", "empty-arch", "failed-lipo"):
                def runner(arguments, **kwargs):
                    result = self.uuid_runner(arguments, **kwargs)
                    if "lipo" in arguments:
                        if mode == "missing-slice":
                            result["stdout"] = b"arm64 x86_64\n"
                        elif mode == "duplicate-arch":
                            result["stdout"] = b"arm64 arm64\n"
                        elif mode == "empty-arch":
                            result["stdout"] = b""
                        elif mode == "failed-lipo":
                            result["code"] = 1
                    elif "dwarfdump" in arguments and mode == "duplicate-uuid":
                        result["stdout"] *= 2
                    return result
                with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "architecture"):
                    preflight.capture_artifact_identity(app, info, runner=runner)

    def test_complete_fat_binary_instrumented_only_in_second_slice_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            first = "01234567-89AB-CDEF-0123-456789ABCDEF"
            second = "11234567-89AB-CDEF-0123-456789ABCDEF"
            def runner(arguments, **kwargs):
                if "lipo" in arguments:
                    output = "arm64 x86_64\n"
                elif "dwarfdump" in arguments:
                    output = "UUID: %s (arm64) fixture\nUUID: %s (x86_64) fixture\n" % (first, second)
                elif "otool" in arguments:
                    if arguments[3] == "arm64":
                        output = otool_fixture(first)
                    else:
                        self.assertEqual(arguments[3], "x86_64")
                        output = otool_fixture(second, ("__text", "__llvm_prf_bits"), 16777223, 3)
                else:
                    self.fail("Unexpected command")
                return {"code": 0, "stdout": output.encode(), "stderr": b"", "oversized": False}
            identity = preflight.capture_artifact_identity(app, info, runner=runner)
            instrumentation = preflight.capture_build_instrumentation(app, identity, runner=runner)
            self.assertEqual(len(instrumentation["binaries"]), 4)
            self.assertTrue(instrumentation["llvmProfileInstrumented"])
            self.assertEqual({(item["architecture"], tuple(item["llvmProfileSections"]))
                              for item in instrumentation["binaries"]},
                             {("arm64", ()), ("x86_64", ("__llvm_prf_bits",))})
            performance = preflight.load_release_module("compare_performance")
            candidate = performance_fixture()
            candidate.update(artifactIdentity=identity, buildInstrumentation=instrumentation)
            with self.assertRaisesRegex(ValueError, "instrumentation must be absent"):
                performance.compare(candidate, candidate, qualify=True)

    def test_section_parser_rejects_missing_wrong_or_partial_architecture(self):
        identifier = "01234567-89AB-CDEF-0123-456789ABCDEF"
        valid = otool_fixture(identifier)
        self.assertEqual(preflight.llvm_profile_sections(valid, "arm64", identifier), [])
        instrumented = otool_fixture(identifier, ("__text", "__llvm_prf_cnts", "__llvm_covmap"))
        self.assertEqual(preflight.llvm_profile_sections(instrumented, "arm64", identifier),
                         ["__llvm_covmap", "__llvm_prf_cnts"])
        malformed = ["", "fixture: No architecture found", valid.replace("16777228", "16777223"),
                     valid.replace("16777228 0", "16777228 2"), valid + valid,
                     valid.replace(identifier, "11234567-89AB-CDEF-0123-456789ABCDEF"),
                     valid.replace("nsects 1", "nsects 2"), valid.replace("sectname __text", "sectname"),
                     valid.replace("Load command 1", "Load command 3"),
                     valid.replace("cmdsize 24", "cmdsize 25"), valid.replace("cmd LC_UUID", ""),
                     valid.replace("nsects 1", "nsects broken"), valid.split("Load command 1")[0]]
        for output in malformed:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "inspection"):
                preflight.llvm_profile_sections(output, "arm64", identifier)
        with self.assertRaisesRegex(ValueError, "inspection"):
            preflight.llvm_profile_sections(valid, "unknown", identifier)
        self.assertEqual(preflight.llvm_profile_sections(
            otool_fixture(identifier, cputype=16777223, cpusubtype=3), "x86_64", identifier), [])

    def test_actual_app_instrumentation_cannot_be_hidden_by_report(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            paths = self.write_reports(directory, app, info)
            def runner(arguments, **kwargs):
                result = self.uuid_runner(arguments, **kwargs)
                if "otool" in arguments and Path(arguments[-1]).name != "Keystorm":
                    identifier = "11234567-89AB-CDEF-0123-456789ABCDEF"
                    result["stdout"] = otool_fixture(identifier, ("__text", "__llvm_prf_names")).encode()
                return result
            result = preflight.performance_qualification(app, info, *paths, runner=runner)
            self.assertFalse(result["passed"], result)
            self.assertTrue(result["build_instrumentation"]["llvmProfileInstrumented"])
            for bad in ({"code": 0, "stdout": b"", "stderr": b"", "oversized": False},
                        {"code": 1, "stdout": b"", "stderr": b"tool failed", "oversized": False},
                        {"code": 0, "stdout": b"", "stderr": b"", "oversized": True}):
                def broken(arguments, **kwargs):
                    return bad if "otool" in arguments else self.uuid_runner(arguments, **kwargs)
                with self.subTest(response=bad):
                    self.assertFalse(preflight.performance_qualification(app, info, *paths, runner=broken)["passed"])

    def test_missing_either_raw_report_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            for baseline, candidate in ((None, None), (Path(directory) / "absent.json", None),
                                        (None, Path(directory) / "absent.json"),
                                        (Path(directory) / "absent.json", Path(directory) / "absent.json")):
                result = preflight.performance_qualification(app, info, baseline, candidate, runner=self.uuid_runner)
                self.assertFalse(result["passed"])
                self.assertTrue(result["errors"])

    def test_matching_fresh_raw_evidence_passes_without_trusting_report_status(self):
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            paths = self.write_reports(directory, app, info)
            result = preflight.performance_qualification(app, info, *paths, runner=self.uuid_runner)
            self.assertTrue(result["passed"], result)
            self.assertTrue(result["comparison"]["qualified"])

    def test_failed_stale_malformed_or_mismatched_candidate_never_passes(self):
        def missed_budget(report):
            report["qualified"] = True
            for sample in report["passes"]:
                sample["finishToCleanMilliseconds"] = 2000

        mutations = [missed_budget,
                     lambda report: report.update(qualificationFailures=["native invariant failed"]),
                     lambda report: report.pop("hostWorkspaceInitialized"),
                     lambda report: report["passes"][-1]["resourcesAfterPass"].pop("textModelLoads"),
                     lambda report: report.update(generatedAt=(datetime.datetime.now(datetime.timezone.utc)
                                                               - datetime.timedelta(days=8)).isoformat()),
                     lambda report: report["artifactIdentity"].update(buildNumber="other-build"),
                     lambda report: report["artifactIdentity"]["machoUUIDs"].pop(
                         "Contents/Frameworks/Foo.framework/Versions/A/Foo"),
                     lambda report: report["artifactIdentity"]["machoUUIDs"][
                         "Contents/Frameworks/Foo.framework/Versions/A/Foo"][0].update(
                             uuid="21234567-89AB-CDEF-0123-456789ABCDEF"),
                     lambda report: report.update(operatingSystem="other OS")]
        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            for mutate in mutations:
                paths = self.write_reports(directory, app, info, mutate)
                with self.subTest(mutation=mutate):
                    result = preflight.performance_qualification(app, info, *paths, runner=self.uuid_runner)
                    self.assertFalse(result["passed"], result)
                    self.assertTrue(result["errors"], result)
            paths[1].write_text('{"broken":')
            self.assertFalse(preflight.performance_qualification(app, info, *paths, runner=self.uuid_runner)["passed"])

    def test_preflight_cli_requires_performance_check_for_overall_success(self):
        def fake_command(arguments, timeout=20, input_data=None):
            stdout = b""
            if "dwarfdump" in arguments or "lipo" in arguments or ("otool" in arguments and "-h" in arguments):
                return self.uuid_runner(arguments, timeout, input_data)
            if "-archs" in arguments:
                stdout = b"arm64"
            elif "-show-build" in arguments:
                stdout = b"minos 27.0"
            elif "--entitlements" in arguments:
                stdout = plistlib.dumps({"com.apple.security.device.audio-input": True})
            elif "--display" in arguments:
                stdout = b"Authority=Developer ID Application: Example\nflags=0x10000(runtime)"
            elif input_data:
                request = json.loads(input_data[len(preflight.PREFIX):])
                stdout = preflight.PREFIX + json.dumps({"version": 1, "id": request["id"],
                                                       "succeeded": True, "processID": 42}).encode() + b"\n"
            return {"code": 0, "stdout": stdout, "stderr": b"", "oversized": False}

        with tempfile.TemporaryDirectory() as directory:
            app, info = self.make_artifact(directory)
            (app / "Contents/Resources/ThirdPartyNotices.txt").write_text(" ".join(preflight.COMPONENTS) + "x" * 11000)
            paths = self.write_reports(directory, app, info)
            audit_stub = SimpleNamespace(audit=lambda *args, **kwargs: {"passed": True, "findings": [], "items": []})
            with mock.patch.object(preflight, "command", fake_command), \
                    mock.patch.object(preflight, "load_audit_module", return_value=audit_stub), \
                    mock.patch.object(preflight.sys, "platform", "darwin"):
                for supplied, expected in ((False, 1), (True, 0)):
                    arguments = [str(app)]
                    if supplied:
                        arguments += ["--performance-baseline", str(paths[0]), "--performance-candidate", str(paths[1])]
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        status = preflight.main(arguments)
                    result = json.loads(output.getvalue())
                    self.assertEqual(status, expected, result)
                    check = next(item for item in result["checks"] if item["check"] == "performance_qualification")
                    self.assertEqual(check["passed"], supplied)


class PreflightTests(unittest.TestCase):
    def test_development_files_flag_repository_documents_and_dotfiles(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(directory)
            resources = app / "Contents" / "Resources"
            for name in ("README.md", "ThirdPartyNotices.txt", ".gitignore"):
                (resources / name).write_text("x")
            nested = resources / "mlx-swift_Cmlx.bundle" / "Contents" / "README.md"
            nested.parent.mkdir(parents=True, exist_ok=True)
            nested.write_text("third-party readme")  # Only top-level Resources documents are flagged.
            self.assertEqual(sorted(preflight.development_files(app)),
                             ["Contents/Resources/.gitignore", "Contents/Resources/README.md"])
            for name in ("README.md", ".gitignore"):
                (resources / name).unlink()
            self.assertEqual(preflight.development_files(app), [])

    def test_first_line_tolerates_empty_detail(self):
        self.assertEqual(preflight.first_line("one\ntwo"), "one")
        self.assertEqual(preflight.first_line(""), "(no detail)")
        self.assertEqual(preflight.first_line(None), "(no detail)")

    def test_runtime_loading_rejects_build_machine_paths(self):
        outputs = {}

        def fake_command(arguments, timeout=20, input_data=None):
            return {"code": 0, "stdout": outputs[Path(arguments[-1]).name].encode(), "stderr": b"",
                    "oversized": False}

        def load_command(kind, field, value):
            return "Load command 1\n          cmd %s\n      cmdsize 56\n         %s %s (offset 24)\n" % (kind, field, value)

        original = preflight.command, preflight.in_shared_cache
        preflight.command = fake_command
        # Stand-in for the dyld shared cache, so the result does not depend on this Mac's OS.
        preflight.in_shared_cache = lambda path: path in ("/usr/lib/swift/libswiftCore.dylib",)
        try:
            with tempfile.TemporaryDirectory() as directory:
                app = make_app(directory)
                macos = Path(os.path.realpath(app)) / "Contents" / "MacOS"
                (macos / "libInside.dylib").write_bytes(thin_header(filetype=6))
                outputs["Keystorm"] = (load_command("LC_LOAD_DYLIB", "name", "/usr/lib/libSystem.B.dylib")
                                        + load_command("LC_LOAD_DYLIB", "name", "@rpath/libInside.dylib")
                                        + load_command("LC_LOAD_DYLIB", "name", "@rpath/libswiftCore.dylib")
                                        + load_command("LC_LOAD_WEAK_DYLIB", "name", "@rpath/libOptional.dylib")
                                        + load_command("LC_RPATH", "path", "@executable_path")
                                        + load_command("LC_RPATH", "path", "/usr/lib/swift"))
                binaries = [(macos / "Keystorm", ["arm64"])]
                self.assertEqual(preflight.runtime_loading(app, macos / "Keystorm", binaries), [])
                outputs["Keystorm"] += (load_command("LC_RPATH", "path", "/Users/me/DerivedData/Build/Products/Debug")
                                         + load_command("LC_LOAD_DYLIB", "name", "/opt/homebrew/lib/libfoo.dylib")
                                         + load_command("LC_LOAD_DYLIB", "name", "@rpath/libMissing.dylib"))
                problems = preflight.runtime_loading(app, macos / "Keystorm", binaries)
                self.assertEqual(len(problems), 3, problems)
                self.assertIn("absolute rpath", problems[0])
        finally:
            preflight.command, preflight.in_shared_cache = original


def sample(elapsed, footprint, **extra):
    row = {column: None for column in soak.SAMPLE_COLUMNS}
    row.update({"elapsed_s": elapsed, "combined_footprint_bytes": footprint, "app_footprint_bytes": footprint,
                "app_rss_bytes": footprint, "app_cpu_percent": 1.0, "combined_cpu_percent": 1.0,
                "worker_count": 0, "workers_footprint_bytes": 0, "thermal_state": "nominal",
                "power_source": "battery", "battery_percent": 90, "low_power_mode": False,
                "app_lifetime_max_footprint_bytes": footprint})
    row.update(extra)
    return row


class SoakTests(unittest.TestCase):
    def test_parsers(self):
        self.assertEqual(soak.parse_pmset_batt(
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t83%; discharging; 5:10 remaining present: true"),
            {"power_source": "battery", "battery_percent": 83, "battery_state": "discharging"})
        self.assertEqual(soak.parse_pmset_batt("Now drawing from 'AC Power'\n"),
                         {"power_source": "ac", "battery_percent": None, "battery_state": None})
        self.assertEqual(soak.parse_sysctl_memory("64\ntotal = 2048.00M  used = 759.50M  free = 1288.50M  (encrypted)\n"),
                         {"memory_free_percent": 64, "swap_used_bytes": int(759.5 * 1024 * 1024)})
        self.assertEqual(soak.parse_duration("90m"), 5400)
        self.assertEqual(soak.parse_duration("8h"), 28800)
        self.assertEqual(soak.parse_duration("0", allow_zero=True), 0)
        for bad in ("0", "-5", "ten", "5d"):
            with self.assertRaises(ValueError):
                soak.parse_duration(bad)

    def test_statistics(self):
        self.assertEqual(soak.percentile(list(range(1, 101)), 0.95), 95)
        self.assertEqual(soak.percentile([7], 0.5), 7)
        self.assertIsNone(soak.stats([None, None]))
        self.assertEqual(soak.stats([3, None, 1, 2])["p50"], 2)
        self.assertAlmostEqual(soak.slope_per_hour([(0, 0), (1800, 50), (3600, 100)]), 100)

    def test_growth_plateau_growth_and_short_run(self):
        plateau = [sample(t, 1000 * soak.MIB + (t % 7)) for t in range(0, 3600, 10)]
        growing = [sample(t, 1000 * soak.MIB + t * 100_000) for t in range(0, 3600, 10)]
        self.assertLess(soak.growth_after_warmup(plateau, 600, 600)["bytes"], 10)
        self.assertGreater(soak.growth_after_warmup(growing, 600, 600)["bytes"], 128 * soak.MIB)
        short = soak.growth_after_warmup(plateau[:100], 600, 600)
        self.assertIsNone(short["bytes"])
        self.assertTrue(short["reason"])
        # An interval longer than the window (or a gap right after warmup) leaves no sample
        # within one window of the warmup; the comparison must still work, not crash.
        sparse = [sample(t, 1000 * soak.MIB + t * 100_000) for t in range(0, 7200, 420)]
        result = soak.growth_after_warmup(sparse, 600, 60)
        self.assertEqual(result["baseline_median_bytes"], 1000 * soak.MIB + 840 * 100_000)
        self.assertGreater(result["bytes"], 0)

    def test_summary_compares_plan_budgets_and_counts_states(self):
        rows = [sample(t, 5 * soak.GIB, thermal_state="fair" if t == 30 else "nominal",
                       battery_percent=90 - t // 10, app_energy_nj=t * 10**9, app_idle_wakeups=t)
                for t in range(0, 70, 10)]
        rows[2]["worker_count"] = 1
        summary = soak.summarize(rows, {"label": "x"}, 10, 0, 10, {42}, 5 * 10**9, {42: 2 * soak.GIB})
        observed = summary["plan_budgets"]["observed"]
        self.assertFalse(observed["within_target"])
        self.assertTrue(observed["within_hard_budget"])
        self.assertEqual(summary["thermal"], {"samples_by_state": {"nominal": 6, "fair": 1}, "worst": "fair"})
        self.assertEqual(summary["power"]["battery_percent_first"], 90)
        self.assertEqual(summary["power"]["battery_percent_last"], 84)
        self.assertAlmostEqual(summary["energy"]["app_average_watts"], 1.0)
        self.assertEqual(summary["energy"]["workers_joules_observed"], 5.0)
        self.assertEqual(summary["workers"], {"distinct_pids": 1, "max_concurrent": 1, "samples_with_worker": 1})
        self.assertEqual(summary["memory"]["worker_lifetime_max_footprint_bytes"], 2 * soak.GIB)

    def test_find_apps_excludes_workers_and_other_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            app = make_app(directory)
            other = Path(directory) / "Other.app" / "Contents"
            (other / "MacOS").mkdir(parents=True)
            (other / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.other"}))
            executable = str(app / "Contents" / "MacOS" / "Keystorm")
            table = [(100, 1, executable), (101, 100, executable), (102, 100, "/usr/bin/say"),
                     (200, 1, str(other / "MacOS" / "Other"))]
            paths = {100: executable, 101: executable, 102: "/usr/bin/say", 200: str(other / "MacOS" / "Other")}
            self.assertEqual(soak.find_apps("dev.mitternacht.Keystorm", table, paths.get, {}), [100])
            self.assertEqual(soak.children(100, executable, table, paths.get), [(101, "worker"), (102, "child")])
            table.append((300, 1, executable))
            paths[300] = executable
            self.assertEqual(soak.find_apps("dev.mitternacht.Keystorm", table, paths.get, {}), [100, 300])


if __name__ == "__main__":
    unittest.main()
