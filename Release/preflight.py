#!/usr/bin/env python3
"""Read-only, offline release checks for a user-selected Keystorm app/archive.

Usage: python3 -I Release/preflight.py /path/to/Keystorm.app
       python3 -I Release/preflight.py /path/to/Keystorm.xcarchive --output report.json
       python3 -I Release/preflight.py /path/to/Keystorm.app --development-identity
This never signs, notarizes, downloads, changes credentials, or modifies the app.
The ping starts only the private worker, with an empty temporary model directory;
--no-worker-ping skips it and records the check as failed.
It also runs Release/audit_signatures.py on every nested code item, checks that bundled
binaries load libraries only from the app or the system (no build-machine paths), and
looks for repository documents and dotfiles in the bundle.
--development-identity checks a Release-configuration build signed with the Apple
Development identity: it expects that authority instead of Developer ID and treats a
missing secure timestamp as a warning. Such a report is never a distributable result.
Passing this check does not qualify microphone accuracy, sustained performance,
notarization/Gatekeeper, or installation on another Mac.
"""
import argparse
import ctypes
import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

BUNDLE_ID = "dev.mitternacht.Keystorm"
# InferenceWorkerClient refuses to start a worker unless the executable has this name.
EXECUTABLE_NAME = "Keystorm"
# Repository documents (Markdown) must not ship inside the app.
DEVELOPMENT_SUFFIX = ".md"
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
VERSION_PATTERN = r"\d+(?:\.\d+){0,2}"
PREFIX = b"KEYSTORM-RPC/1 "
MAX_CAPTURE = 1024 * 1024
COMPONENTS = (
    "FluidAudio", "mlx-swift", "mlx-swift-lm", "xgrammar", "swift-transformers",
    "swift-huggingface", "swift-collections", "swift-numerics", "swift-crypto",
    "swift-asn1", "EventSource", "Jinja", "yyjson",
)


def command(arguments, timeout=20, input_data=None):
    # Spooling bounds the report's memory even if a broken worker logs excessively.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            result = subprocess.run(arguments, input=input_data, stdout=out, stderr=err,
                                    timeout=timeout, check=False)
            code = result.returncode
        except subprocess.TimeoutExpired:
            return {"code": -1, "stdout": b"", "stderr": b"Timed out", "oversized": False}
        except OSError as error:
            return {"code": -1, "stdout": b"", "stderr": str(error).encode(), "oversized": False}
        oversized = out.tell() > MAX_CAPTURE or err.tell() > MAX_CAPTURE
        out.seek(0)
        err.seek(0)
        return {"code": code, "stdout": out.read(MAX_CAPTURE),
                "stderr": err.read(MAX_CAPTURE), "oversized": oversized}


def text(result):
    return (result["stdout"] + result["stderr"]).decode("utf-8", errors="replace").strip()


def resolve_app(path):
    path = path.expanduser().resolve(strict=True)
    if path.suffix == ".xcarchive":
        apps = sorted((path / "Products" / "Applications").glob("*.app"))
        if len(apps) != 1:
            raise ValueError("The archive must contain exactly one app in Products/Applications.")
        return apps[0]
    if path.suffix != ".app" or not path.is_dir():
        raise ValueError("Select a .app bundle or .xcarchive directory.")
    return path


def load_audit_module():
    # Loaded by explicit path so `python3 -I` (no script directory on sys.path) still works,
    # and without writing __pycache__ into the repository.
    sys.dont_write_bytecode = True
    path = Path(__file__).resolve().with_name("audit_signatures.py")
    spec = importlib.util.spec_from_file_location("keystorm_audit_signatures", path)
    if spec is None or spec.loader is None:
        raise ImportError("Cannot load %s" % path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def development_files(app):
    """Return bundle-relative paths of repository documents (Markdown in the app's own
    Resources folder) and dotfiles shipped inside the bundle."""
    found = []
    for current, directories, files in os.walk(app, followlinks=False):
        directories.sort()
        for entry in directories + sorted(files):
            relative = (Path(current) / entry).relative_to(app)
            in_resources = relative.parent == Path("Contents/Resources")
            if entry.startswith(".") or (in_resources and entry.lower().endswith(DEVELOPMENT_SUFFIX)):
                found.append(str(relative))
    return found


def first_line(detail):
    lines = str(detail or "").splitlines()
    return lines[0] if lines else "(no detail)"




def load_commands(binary, architectures):
    """Return {"dylibs": [(name, weak)], "rpaths": [...]} from `otool -l` for one slice."""
    arguments = ["/usr/bin/otool"]
    if len(architectures) > 1:
        arguments += ["-arch", "arm64" if "arm64" in architectures else architectures[0]]
    result = command(arguments + ["-l", str(binary)], timeout=60)
    dylibs, rpaths, current = [], [], None
    for line in text(result).splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            current = stripped.split()[1]
        elif stripped.startswith("name ") and current in (
                "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LAZY_LOAD_DYLIB",
                "LC_LOAD_UPWARD_DYLIB"):
            dylibs.append((re.sub(r"\s+\(offset \d+\)$", "", stripped[5:]).strip(),
                           current == "LC_LOAD_WEAK_DYLIB"))
        elif stripped.startswith("path ") and current == "LC_RPATH":
            rpaths.append(re.sub(r"\s+\(offset \d+\)$", "", stripped[5:]).strip())
    return {"ok": result["code"] == 0, "dylibs": dylibs, "rpaths": rpaths, "error": text(result)[:512]}


def in_shared_cache(path):
    """True if dyld can load this system path: on disk or in the dyld shared cache."""
    if os.path.exists(path):
        return True
    try:
        lookup = ctypes.CDLL("/usr/lib/libSystem.B.dylib")._dyld_shared_cache_contains_path
    except (OSError, AttributeError):
        return True  # Cannot tell; system paths are trusted rather than reported falsely.
    lookup.argtypes = [ctypes.c_char_p]
    lookup.restype = ctypes.c_bool
    return bool(lookup(os.fsencode(path)))


def runtime_loading(app, main_executable, binaries):
    """Check that every non-system library a bundled binary loads resolves inside the app
    and that no rpath or install name points at the build machine."""
    root = Path(os.path.realpath(app))
    executable_dir = Path(os.path.realpath(main_executable)).parent
    main_rpaths = []
    parsed = {}
    for binary, architectures in binaries:
        parsed[binary] = load_commands(binary, architectures)
        if Path(os.path.realpath(binary)) == Path(os.path.realpath(main_executable)):
            main_rpaths = parsed[binary]["rpaths"]
    problems = []

    def expand(entry, loader_dir):
        return Path(os.path.normpath(entry.replace("@executable_path", str(executable_dir))
                                     .replace("@loader_path", str(loader_dir))))

    def loadable(candidate):
        if str(candidate).startswith(SYSTEM_PREFIXES):
            return in_shared_cache(str(candidate))
        return candidate.is_file() and Path(os.path.realpath(candidate)).is_relative_to(root)

    for binary, commands in parsed.items():
        label = str(Path(os.path.realpath(binary)).relative_to(root))
        if not commands["ok"]:
            problems.append("%s: otool failed: %s" % (label, commands["error"]))
            continue
        loader_dir = Path(os.path.realpath(binary)).parent
        for rpath in commands["rpaths"]:
            if rpath.startswith("/") and not rpath.startswith(SYSTEM_PREFIXES):
                problems.append("%s: absolute rpath outside the system: %s" % (label, rpath))
        search = [expand(entry, loader_dir) for entry in commands["rpaths"] + main_rpaths]
        for name, weak in commands["dylibs"]:
            if name.startswith(SYSTEM_PREFIXES):
                continue
            if name.startswith("@rpath/"):
                resolved = any(loadable(directory / name[len("@rpath/"):]) for directory in search)
            elif name.startswith(("@executable_path/", "@loader_path/")):
                resolved = loadable(expand(name, loader_dir))
            else:
                resolved = False
            if not resolved and not weak:
                problems.append("%s: %s does not resolve inside the app or the system" % (label, name))
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--output", type=Path, help="Save JSON to this new report file; never overwrites.")
    parser.add_argument("--minimum-os", default="27.0", help="Expected declared minimum macOS (default 27.0).")
    parser.add_argument("--expect-version", help="Required CFBundleShortVersionString, e.g. 1.0.")
    parser.add_argument("--expect-build", help="Required CFBundleVersion, e.g. 1.")
    parser.add_argument("--development-identity", action="store_true",
                        help="Expect Apple Development signing (Release configuration). Never distributable.")
    parser.add_argument("--no-worker-ping", action="store_true",
                        help="Do not start the worker; the ping check is then recorded as failed.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Run on macOS with Xcode command line tools installed.")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", args.minimum_os):
        parser.error("--minimum-os must be a numeric macOS version.")
    for value, flag in ((args.expect_version, "--expect-version"), (args.expect_build, "--expect-build")):
        if value is not None and not re.fullmatch(VERSION_PATTERN, value):
            parser.error("%s must be one to three dot-separated integers." % flag)
    if args.output and os.path.lexists(args.output.expanduser()):
        # Checked before the deep verification, which can take minutes; the final write still never overwrites.
        parser.error("%s already exists; reports are never overwritten." % args.output)
    try:
        app = resolve_app(args.artifact)
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        name = info["CFBundleExecutable"]
        if not isinstance(name, str) or Path(name).name != name:
            raise ValueError("The app has an invalid executable name.")
        executable = app / "Contents" / "MacOS" / name
        if not executable.is_file():
            raise ValueError("The app executable is missing.")
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        parser.error(str(error))

    checks = []
    advisories = []
    def check(name, passed, detail):
        checks.append({"check": name, "passed": bool(passed),
                       "detail": detail if isinstance(detail, (dict, list)) else str(detail)})

    identity_ok = info.get("CFBundleIdentifier") == BUNDLE_ID
    check("bundle_identity", identity_ok, info.get("CFBundleIdentifier"))
    check("executable_name", name == EXECUTABLE_NAME,
          "%s (the worker client only starts an executable named %s)" % (name, EXECUTABLE_NAME))
    version = str(info.get("CFBundleShortVersionString", ""))
    check("marketing_version", re.fullmatch(VERSION_PATTERN, version)
          and (args.expect_version is None or version == args.expect_version),
          (version or "Missing") + ("" if args.expect_version is None else " (expected %s)" % args.expect_version))
    build_number = str(info.get("CFBundleVersion", ""))
    check("build_number", re.fullmatch(VERSION_PATTERN, build_number)
          and (args.expect_build is None or build_number == args.expect_build),
          (build_number or "Missing") + ("" if args.expect_build is None else " (expected %s)" % args.expect_build))
    check("microphone_usage", bool(str(info.get("NSMicrophoneUsageDescription", "")).strip()),
          info.get("NSMicrophoneUsageDescription", "Missing"))
    declared_os = str(info.get("LSMinimumSystemVersion", ""))
    check("minimum_os_plist", declared_os == args.minimum_os, declared_os or "Missing")
    arch = command(["/usr/bin/lipo", "-archs", str(executable)])
    check("apple_silicon", arch["code"] == 0 and "arm64" in text(arch).split(), text(arch))
    build = command(["/usr/bin/xcrun", "vtool", "-show-build", str(executable)])
    minimums = re.findall(r"^\s*minos\s+(\S+)", text(build), flags=re.MULTILINE)
    check("minimum_os_binary", build["code"] == 0 and bool(minimums)
          and all(value == args.minimum_os for value in minimums),
          ", ".join(minimums) if minimums else text(build))

    shipped_documents = development_files(app)
    check("no_development_files", not shipped_documents,
          shipped_documents or "No repository documents or dotfiles in the bundle.")

    verification = command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
                           timeout=900)
    check("signature_integrity", verification["code"] == 0, text(verification))
    signature = command(["/usr/bin/codesign", "--display", "--verbose=4", str(app)])
    description = text(signature)
    authority = "Apple Development:" if args.development_identity else "Developer ID Application:"
    check("apple_development_identity" if args.development_identity else "developer_id_application",
          signature["code"] == 0 and "Authority=" + authority in description,
          "\n".join(line for line in description.splitlines()
                    if line.startswith(("Authority=", "TeamIdentifier=", "Signature="))))
    check("hardened_runtime", bool(re.search(r"flags=.*\bruntime\b", description)),
          "\n".join(line for line in description.splitlines() if "flags=" in line))
    entitlement_result = command(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)])
    try:
        entitlements = plistlib.loads(entitlement_result["stdout"])
    except (ValueError, plistlib.InvalidFileException):
        entitlements = {}
    check("audio_input_entitlement", entitlements.get("com.apple.security.device.audio-input") is True,
          "com.apple.security.device.audio-input must be true in the actual signature.")
    check("release_debugger_entitlement", entitlements.get("com.apple.security.get-task-allow") is not True,
          "get-task-allow must be absent or false in the distributed app.")

    audit_report = None
    try:
        audit_module = load_audit_module()
        audit_report = audit_module.audit(app, configuration="release",
                                          distribution=not args.development_identity)
    except Exception as error:  # A broken audit must fail the checks, never skip them.
        check("nested_signature_audit", False, "Audit did not run: %s" % error)
        check("runtime_loading", False, "Not run: it uses the signature audit's item list.")
    if audit_report is not None:
        failures = [finding for finding in audit_report["findings"] if finding["severity"] == "failure"]
        check("nested_signature_audit", audit_report["passed"],
              {"items": [record["path"] for record in audit_report["items"]],
               "failures": ["%s [%s]: %s" % (finding["check"], finding["path"], first_line(finding["detail"]))
                            for finding in failures]})
        advisories += ["signature audit: %s [%s]: %s" % (finding["check"], finding["path"],
                                                          first_line(finding["detail"]))
                       for finding in audit_report["findings"] if finding["severity"] == "warning"]
        binaries = []
        for record in audit_report["items"]:
            if record["executable"] and record["macho_type"] in ("execute", "dylib", "bundle"):
                binaries.append((Path(os.path.realpath(app)) / record["executable"], record["architectures"]))
        loading = runtime_loading(app, executable, binaries)
        check("runtime_loading", not loading, loading or "%d binaries: every non-system library "
              "resolves inside the app; no build-machine rpaths." % len(binaries))

    notices_path = app / "Contents" / "Resources" / "ThirdPartyNotices.txt"
    try:
        notices = notices_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        notices = ""
    absent = [component for component in COMPONENTS if component.lower() not in notices.lower()]
    check("bundled_attributions", len(notices.encode()) > 10_000 and not absent,
          "Missing component notices: " + ", ".join(absent) if absent else str(notices_path))
    # Marker checks detect packaging omissions; license completeness still needs review.

    if args.no_worker_ping:
        check("worker_ping_and_teardown", False, "Skipped by --no-worker-ping; the worker was not started.")
    elif identity_ok:
        request_id = str(uuid.uuid4()).upper()
        request = {"version": 1, "id": request_id, "operation": "ping", "parentFootprint": 0,
                   "segments": [], "transcripts": [], "contexts": [], "priorFacts": [],
                   "selectedBlockIDs": [], "sources": []}
        with tempfile.TemporaryDirectory(prefix="Keystorm-release-ping-") as models:
            ping = command([str(executable), "--inference-worker", "--model-directory", models],
                           input_data=PREFIX + json.dumps(request).encode() + b"\n")
        lines = [line for line in ping["stdout"].splitlines() if line.startswith(PREFIX)]
        try:
            reply = json.loads(lines[0][len(PREFIX):]) if len(lines) == 1 else {}
        except (ValueError, UnicodeError):
            reply = {}
        passed = (ping["code"] == 0 and not ping["oversized"]
                  and reply.get("version") == 1 and reply.get("id", "").upper() == request_id
                  and reply.get("succeeded") is True and reply.get("processID", 0) > 0)
        check("worker_ping_and_teardown", passed,
              {"exit_code": ping["code"], "reply": reply, "stderr": text({"stdout": b"", "stderr": ping["stderr"]})[:2048]})
    else:
        check("worker_ping_and_teardown", False, "Skipped: selected artifact is not Keystorm.")

    not_assessed = ["Notarization and stapled ticket", "Gatekeeper on a clean quarantined download",
                    "Natural speech fidelity and sustained resource qualification",
                    "License completeness and model redistribution terms"]
    if args.development_identity:
        not_assessed.insert(0, "Developer ID signing and secure timestamps (development identity mode)")
    report = {"artifact": str(app), "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "identity_mode": "development" if args.development_identity else "developer-id",
              "passed": all(item["passed"] for item in checks), "checks": checks,
              "advisories": advisories, "signature_audit": audit_report,
              "not_assessed": not_assessed}
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        with args.output.expanduser().open("x", encoding="utf-8") as destination:
            destination.write(encoded)
    sys.stdout.write(encoded)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
