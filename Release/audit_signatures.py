#!/usr/bin/env python3
"""Read-only nested code-signature audit for a built Keystorm .app or .xcarchive.

Usage: python3 -I Release/audit_signatures.py /path/to/Keystorm.app --json audit.json
       python3 -I Release/audit_signatures.py /path/to/Keystorm.app --configuration debug
       python3 -I Release/audit_signatures.py /path/to/Keystorm.xcarchive --distribution

Walks every nested code item: the app, frameworks, dylibs, XPC services, helper apps
and tools, plug-ins, app extensions, login items, and any other Mach-O file, so a
separately bundled inference worker is covered if one is ever added. For each item it
runs codesign and checks strict deep verification, one TeamIdentifier for all items,
Hardened Runtime on every executable that notarization requires it for, a secure
timestamp, no get-task-allow in a Release build, and a designated requirement that is
anchored to an Apple-issued certificate of the team rather than a bare cdhash. It
prints a table, records each item's entitlements in the JSON report, and exits 1 on
any hard failure.

Apple Development signatures have no secure timestamp and a requirement pinned to one
development certificate; both are warnings by default. --distribution makes them
failures and also requires Developer ID Application authority.
This never signs, re-signs, notarizes, launches, or modifies the app, and makes no
network requests. It does not assess notarization, stapling, Gatekeeper, or whether
libraries load at runtime on another Mac.
"""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile

MAX_CAPTURE = 1024 * 1024
BUNDLE_EXTENSIONS = {
    ".app", ".framework", ".xpc", ".appex", ".bundle", ".plugin", ".xctest",
    ".systemextension", ".kext", ".dext", ".qlgenerator", ".mdimporter", ".saver",
    ".prefpane",
}
FILETYPES = {1: "object", 2: "execute", 6: "dylib", 7: "dylinker", 8: "bundle",
             9: "dylib-stub", 10: "dsym", 11: "kext-bundle", 12: "fileset"}
CPU_TYPES = {7: "i386", 0x01000007: "x86_64", 12: "arm", 0x0100000C: "arm64",
             0x0200000C: "arm64_32"}
MH_MAGIC, MH_MAGIC_64 = 0xFEEDFACE, 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
RUNTIME_FLAG, ADHOC_FLAG, LINKER_SIGNED_FLAG = 0x10000, 0x2, 0x20000
GET_TASK_ALLOW = "com.apple.security.get-task-allow"
# Hardened Runtime exceptions are legal but weaken the runtime; each one needs a reason.
RUNTIME_EXCEPTIONS = (
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.debugger",
)
NOT_ASSESSED = [
    "Notarization, stapled ticket and Gatekeeper on a quarantined download",
    "Runtime library loading and library validation on another Mac",
    "Whether each entitlement is needed (review the per-item dump)",
]


def command(arguments, timeout=60):
    # Spooling bounds memory even if a tool prints far more than expected.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            result = subprocess.run(arguments, stdout=out, stderr=err, timeout=timeout, check=False)
            code = result.returncode
        except subprocess.TimeoutExpired:
            return {"code": -1, "stdout": b"", "stderr": b"Timed out"}
        except OSError as error:
            return {"code": -1, "stdout": b"", "stderr": str(error).encode()}
        out.seek(0)
        err.seek(0)
        return {"code": code, "stdout": out.read(MAX_CAPTURE), "stderr": err.read(MAX_CAPTURE)}


def text(result):
    return (result["stdout"] + result["stderr"]).decode("utf-8", errors="replace").strip()


def resolve_app(path):
    path = Path(path).expanduser().resolve(strict=True)
    if path.suffix == ".xcarchive":
        apps = sorted((path / "Products" / "Applications").glob("*.app"))
        if len(apps) != 1:
            raise ValueError("The archive must contain exactly one app in Products/Applications.")
        return apps[0]
    if path.suffix != ".app" or not path.is_dir():
        raise ValueError("Select a .app bundle or .xcarchive directory.")
    return path


# --- Mach-O headers ---------------------------------------------------------------

def _thin_header(data):
    if len(data) < 16:
        return None
    for order in ("<", ">"):
        magic = struct.unpack(order + "I", data[:4])[0]
        if magic in (MH_MAGIC, MH_MAGIC_64):
            cputype, cpusubtype, filetype = struct.unpack(order + "iiI", data[4:16])
            return cputype, cpusubtype, filetype
    return None


def _arch_name(cputype, cpusubtype):
    name = CPU_TYPES.get(cputype, "cpu-0x%x" % (cputype & 0xFFFFFFFF))
    if name == "arm64" and cpusubtype & 0xFF == 2:
        return "arm64e"
    return name


def macho_info(path):
    """Return {"filetype", "architectures"} for a Mach-O file, {"filetype": "static-archive"}
    for an ar archive, or None for anything else. Reads headers only."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(4096)
            if head.startswith(b"!<arch>\n"):
                return {"filetype": "static-archive", "architectures": []}
            if len(head) < 8:
                return None
            magic = struct.unpack(">I", head[:4])[0]
            headers = []
            if magic in (FAT_MAGIC, FAT_MAGIC_64):
                count = struct.unpack(">I", head[4:8])[0]
                # Java class files share 0xCAFEBABE; their next word is a version >= 45.
                if not 0 < count < 45:
                    return None
                size = 20 if magic == FAT_MAGIC else 32
                for index in range(count):
                    record = head[8 + index * size:8 + (index + 1) * size]
                    if len(record) < size:
                        return None
                    if magic == FAT_MAGIC:
                        offset = struct.unpack(">I", record[8:12])[0]
                    else:
                        offset = struct.unpack(">Q", record[8:16])[0]
                    handle.seek(offset)
                    header = _thin_header(handle.read(16))
                    if header is None:
                        return None
                    headers.append(header)
            else:
                header = _thin_header(head[:16])
                if header is None:
                    return None
                headers.append(header)
    except OSError:
        return None
    filetypes = {FILETYPES.get(header[2], "type-%d" % header[2]) for header in headers}
    return {"filetype": filetypes.pop() if len(filetypes) == 1 else "mixed",
            "architectures": [_arch_name(header[0], header[1]) for header in headers]}


# --- Discovery --------------------------------------------------------------------

def _inside(path, root):
    try:
        Path(os.path.realpath(path)).relative_to(root)
        return True
    except ValueError:
        return False


def bundle_executable(bundle, root):
    """The bundle's main executable inside the app, or None for a resource-only bundle."""
    name = None
    for plist in (bundle / "Contents" / "Info.plist", bundle / "Resources" / "Info.plist",
                  bundle / "Versions" / "Current" / "Resources" / "Info.plist", bundle / "Info.plist"):
        if plist.is_file():
            try:
                name = plistlib.loads(plist.read_bytes()).get("CFBundleExecutable")
            except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
                name = None
            break
    if not isinstance(name, str) or not name or Path(name).name != name:
        name = bundle.stem if bundle.suffix == ".framework" else None
    if name is None:
        return None
    for candidate in (bundle / "Contents" / "MacOS" / name, bundle / "Versions" / "Current" / name,
                      bundle / name):
        if candidate.is_file() and _inside(candidate, root):
            return Path(os.path.realpath(candidate))
    return None


def bundle_kind(relative, suffix):
    parts = relative.parts
    if suffix == ".framework":
        return "framework"
    if suffix == ".xpc":
        return "xpc-service"
    if suffix == ".appex":
        return "app-extension"
    if suffix == ".xctest":
        return "test-bundle"
    if suffix in (".systemextension", ".kext", ".dext"):
        return "system-extension"
    if suffix == ".app":
        return "login-item" if "LoginItems" in parts else "helper-app"
    return "plug-in" if "PlugIns" in parts else "code-bundle"


def file_kind(relative, filetype):
    if filetype == "execute":
        return "helper-tool"
    if filetype == "dylib":
        return "dylib"
    if filetype == "bundle":
        return "loadable-bundle"
    return filetype


def discover(app):
    """Return (items, resource_bundles, problems). Paths in items are absolute."""
    root = Path(os.path.realpath(app))
    main = bundle_executable(app, root)
    items = [{"path": app, "relative": ".", "kind": "app", "executable": main}]
    claimed = {main} if main else set()
    resource_bundles, problems = [], []
    for current, directories, files in os.walk(app, followlinks=False):
        current = Path(current)
        directories.sort()
        files.sort()
        for name in directories + files:
            path = current / name
            relative = path.relative_to(app)
            if path.is_symlink():
                if not _inside(path, root):
                    problems.append({"severity": "failure", "check": "symlink_escapes_bundle",
                                     "path": str(relative), "detail": os.readlink(path)})
                continue
            if name in directories:
                if path.suffix.lower() not in BUNDLE_EXTENSIONS:
                    continue
                executable = bundle_executable(path, root)
                if executable is None:
                    resource_bundles.append(str(relative))
                    continue
                claimed.add(executable)
                items.append({"path": path, "relative": str(relative),
                              "kind": bundle_kind(relative, path.suffix.lower()),
                              "executable": executable})
                continue
            real = Path(os.path.realpath(path))
            if real in claimed:
                continue
            info = macho_info(path)
            if info is None:
                continue
            if info["filetype"] in ("static-archive", "object"):
                problems.append({"severity": "warning", "check": "unlinked_object_in_bundle",
                                 "path": str(relative),
                                 "detail": "A %s cannot carry a code signature and is not loaded at runtime."
                                           % info["filetype"]})
                continue
            claimed.add(real)
            items.append({"path": path, "relative": str(relative),
                          "kind": file_kind(relative, info["filetype"]), "executable": real})
    for item in items:
        executable = item["executable"]
        item["executable_relative"] = str(executable.relative_to(root)) if executable else None
    return items, resource_bundles, problems


# --- codesign parsing ------------------------------------------------------------

def parse_display(output):
    """Parse `codesign --display --verbose=4` text into a dictionary."""
    fields = {"signed": "code object is not signed at all" not in output, "authorities": [],
              "identifier": None, "team_identifier": None, "timestamp": None,
              "signed_time": None, "flags": None, "flags_text": None, "cdhash": None,
              "signature": None, "runtime_version": None, "format": None}
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        if not separator:
            continue
        value = value.strip()
        if key == "Authority":
            fields["authorities"].append(value)
        elif key == "Identifier":
            fields["identifier"] = value
        elif key == "TeamIdentifier":
            fields["team_identifier"] = None if value == "not set" else value
        elif key == "Timestamp":
            fields["timestamp"] = value
        elif key == "Signed Time":
            fields["signed_time"] = value
        elif key == "CDHash":
            fields["cdhash"] = value
        elif key == "Signature":
            fields["signature"] = value
        elif key == "Runtime Version":
            fields["runtime_version"] = value
        elif key == "Format":
            fields["format"] = value
        elif key == "CodeDirectory v":
            match = re.search(r"flags=(0x[0-9a-fA-F]+)\(([^)]*)\)", line)
            if match:
                fields["flags"] = int(match.group(1), 16)
                fields["flags_text"] = match.group(2)
    return fields


def parse_requirement(output):
    """Return (requirement, implicit) from `codesign --display -r-` output."""
    for line in output.splitlines():
        match = re.match(r"^\s*(#)?\s*designated\s*=>\s*(.+?)\s*$", line)
        if match:
            return match.group(2), bool(match.group(1))
    return None, False


def _decode_name(token):
    token = token.strip()
    if token.startswith("0x"):
        try:
            return bytes.fromhex(token[2:]).decode("utf-8", errors="replace")
        except ValueError:
            return token
    return token.strip('"')


def classify_requirement(requirement):
    """Classify a designated requirement by what it anchors to.

    team: anchor apple generic plus the leaf certificate's team (subject.OU), as in
          Developer ID signatures; certificate: anchor apple generic plus one leaf
          certificate's common name, as in Apple Development signatures;
          cdhash-only, apple-generic-only, unanchored, missing: not team-anchored."""
    if not requirement:
        return {"anchor": "missing"}
    if "anchor apple generic" not in requirement:
        if re.search(r"\banchor apple\b", requirement):
            return {"anchor": "apple-platform"}
        if "cdhash" in requirement:
            return {"anchor": "cdhash-only"}
        return {"anchor": "unanchored"}
    team = re.search(r'certificate leaf\[subject\.OU\]\s*=\s*"?([A-Za-z0-9]+)"?', requirement)
    if team:
        return {"anchor": "team", "team": team.group(1)}
    common = re.search(r'certificate leaf\[subject\.CN\]\s*=\s*(0x[0-9a-fA-F]+|"[^"]*"|[^\s)]+)', requirement)
    if common:
        return {"anchor": "certificate", "common_name": _decode_name(common.group(1))}
    return {"anchor": "apple-generic-only"}


def json_safe(value):
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    if isinstance(value, bytes):
        return {"base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    return value


# --- Audit -----------------------------------------------------------------------

def inspect(item, runner):
    target = str(item["path"])
    display = runner(["/usr/bin/codesign", "--display", "--verbose=4", target])
    fields = parse_display(text(display))
    requirement_result = runner(["/usr/bin/codesign", "--display", "-r-", target])
    requirement, implicit = parse_requirement(text(requirement_result))
    entitlement_result = runner(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", target])
    entitlements, entitlement_error = {}, None
    if entitlement_result["stdout"].strip():
        try:
            entitlements = plistlib.loads(entitlement_result["stdout"])
        except (ValueError, plistlib.InvalidFileException) as error:
            entitlement_error = str(error)
        if not isinstance(entitlements, dict):
            entitlements, entitlement_error = {}, "Entitlements are not a dictionary."
    verification = runner(["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", target],
                          timeout=600) if fields["signed"] else {"code": 1, "stdout": b"",
                                                                  "stderr": b"code object is not signed at all"}
    executable = item.get("executable")
    info = macho_info(executable) if executable else None
    return {
        "path": item["relative"],
        "kind": item["kind"],
        "executable": item.get("executable_relative"),
        "macho_type": info["filetype"] if info else None,
        "architectures": info["architectures"] if info else [],
        "signed": fields["signed"],
        "identifier": fields["identifier"],
        "team_identifier": fields["team_identifier"],
        "authorities": fields["authorities"],
        "signature": fields["signature"],
        "flags": fields["flags_text"],
        "hardened_runtime": bool(fields["flags"] is not None and fields["flags"] & RUNTIME_FLAG),
        "hardened_runtime_required": bool(info and info["filetype"] == "execute"),
        "ad_hoc": bool(fields["flags"] is not None and fields["flags"] & (ADHOC_FLAG | LINKER_SIGNED_FLAG)),
        "secure_timestamp": fields["timestamp"],
        "signed_time": fields["signed_time"],
        "cdhash": fields["cdhash"],
        "runtime_version": fields["runtime_version"],
        "designated_requirement": requirement,
        "designated_requirement_implicit": implicit,
        "requirement_anchor": classify_requirement(requirement),
        "entitlements": json_safe(entitlements),
        "entitlements_error": entitlement_error,
        "verify": {"passed": verification["code"] == 0, "output": text(verification)[:4096]},
        "findings": [],
    }


def evaluate(record, configuration, distribution, expected_team):
    """Append findings to one inspected item. Returns the record."""
    findings = record["findings"]

    def add(severity, check, detail):
        findings.append({"severity": severity, "check": check, "path": record["path"], "detail": detail})

    if record["kind"] == "app" and record["macho_type"] != "execute":
        add("failure", "main_executable", "The app's CFBundleExecutable is missing or not a Mach-O executable.")
    if not record["signed"]:
        add("failure", "signed", "The code object is not signed.")
        return record
    if not record["verify"]["passed"]:
        add("failure", "verify_strict_deep", record["verify"]["output"] or "codesign --verify failed.")
    if record["ad_hoc"]:
        add("failure", "ad_hoc_signature",
            "Ad hoc or linker-only signature (%s); it has no team identity." % record["flags"])
    team = record["team_identifier"]
    if team is None:
        add("failure", "team_identifier", "No TeamIdentifier.")
    elif expected_team and team != expected_team:
        add("failure", "team_identifier", "TeamIdentifier %s differs from %s." % (team, expected_team))
    if record["hardened_runtime_required"] and not record["hardened_runtime"]:
        add("failure", "hardened_runtime",
            "Executable without the Hardened Runtime flag; notarization rejects it.")
    if record["secure_timestamp"] is None:
        detail = ("No secure timestamp. Xcode signs Apple Development builds without one; "
                  "a Developer ID export must, or notarization rejects it.")
        add("failure" if distribution else "warning", "secure_timestamp", detail)
    entitlements = record["entitlements"]
    if entitlements.get(GET_TASK_ALLOW) is True:
        if configuration == "release":
            add("failure", "get_task_allow", "%s is true in a Release build." % GET_TASK_ALLOW)
        else:
            add("warning", "get_task_allow", "%s is true (expected in a Debug build)." % GET_TASK_ALLOW)
    exceptions = [key for key in RUNTIME_EXCEPTIONS if entitlements.get(key) is True]
    if exceptions:
        add("warning", "runtime_exceptions", "Hardened Runtime exceptions: " + ", ".join(exceptions))
    temporary = sorted(key for key in entitlements if key.startswith("com.apple.security.temporary-exception."))
    if temporary and configuration == "release":
        add("warning", "temporary_exceptions",
            "Sandbox temporary-exception entitlements (Xcode adds them for test hosts): " + ", ".join(temporary))
    if record["entitlements_error"]:
        add("failure", "entitlements_readable", record["entitlements_error"])
    name = Path(record["path"]).name
    if name.endswith(".debug.dylib") or name == "__preview.dylib" or record["kind"] == "test-bundle":
        detail = "Debug-only artifact (Xcode debug dylib, preview dylib or embedded test bundle)."
        add("failure" if configuration == "release" else "info", "debug_artifact", detail)
    anchor = record["requirement_anchor"]
    kind = anchor["anchor"]
    if record["designated_requirement_implicit"] or kind in ("missing", "cdhash-only", "unanchored",
                                                             "apple-generic-only", "apple-platform"):
        add("failure", "designated_requirement",
            "Not team-anchored (%s): %s" % (kind, record["designated_requirement"] or "none"))
    elif kind == "team":
        if team and anchor["team"] != team:
            add("failure", "designated_requirement",
                "Requirement names team %s but the signature's team is %s." % (anchor["team"], team))
    elif kind == "certificate":
        detail = ("Anchored to one Apple certificate (%s), not to the team; a renewed or different "
                  "certificate changes the requirement and needs a new privacy grant." % anchor["common_name"])
        add("failure" if distribution else "warning", "designated_requirement", detail)
    requirement = record["designated_requirement"] or ""
    identifier = re.search(r'\bidentifier\s+"?([^"\s]+)"?', requirement)
    if identifier and record["identifier"] and identifier.group(1) != record["identifier"]:
        add("failure", "designated_requirement",
            "Requirement identifier %s differs from signature identifier %s."
            % (identifier.group(1), record["identifier"]))
    leaf = record["authorities"][0] if record["authorities"] else ""
    if distribution and not leaf.startswith("Developer ID Application:"):
        add("failure", "developer_id_authority", "Leaf authority is %r, not Developer ID Application." % leaf)
    return record


def audit(artifact, configuration="release", distribution=False, expected_team=None, runner=command):
    """Audit an app or archive and return the report dictionary."""
    if distribution and configuration != "release":
        raise ValueError("--distribution audits a Release build only.")
    app = resolve_app(artifact)
    items, resource_bundles, problems = discover(app)
    records = [inspect(item, runner) for item in items]
    team = expected_team or (records[0]["team_identifier"] if records else None)
    for record in records:
        evaluate(record, configuration, distribution, team)
    bundle = runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], timeout=900)
    findings = list(problems)
    if bundle["code"] != 0:
        findings.append({"severity": "failure", "check": "bundle_verify_strict_deep", "path": ".",
                         "detail": text(bundle)[:4096]})
    teams = sorted({record["team_identifier"] for record in records if record["team_identifier"]})
    if len(teams) > 1:
        findings.append({"severity": "failure", "check": "single_team", "path": ".",
                         "detail": "Items carry different teams: " + ", ".join(teams)})
    leaf = records[0]["authorities"][0] if records and records[0]["authorities"] else ""
    if not distribution and leaf.startswith("Apple Development:"):
        findings.append({"severity": "warning", "check": "signing_identity", "path": ".",
                         "detail": "Signed with %r: a development signature, not distributable." % leaf})
    debug_hint = configuration == "release" and any(
        finding["check"] in ("debug_artifact", "get_task_allow")
        for record in records for finding in record["findings"])
    for record in records:
        findings.extend(record["findings"])
    notes = []
    executables = [record for record in records[1:] if record["macho_type"] == "execute"]
    if not executables:
        notes.append("No separate executable is bundled. The current source starts the inference worker "
                     "from the main executable with --inference-worker, so the app item covers it.")
    if debug_hint:
        notes.append("This looks like a Debug or development build. Pass --configuration debug to audit it "
                     "as one; a Release build must not have these findings.")
    failures = sum(1 for finding in findings if finding["severity"] == "failure")
    warnings = sum(1 for finding in findings if finding["severity"] == "warning")
    return {
        "tool": "Release/audit_signatures.py",
        "schema": 1,
        "artifact": str(Path(artifact).expanduser()),
        "app": str(app),
        "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "configuration": configuration,
        "distribution": distribution,
        "expected_team": team,
        "passed": failures == 0,
        "failure_count": failures,
        "warning_count": warnings,
        "bundle_verification": {"passed": bundle["code"] == 0, "output": text(bundle)[:4096]},
        "team_identifiers": teams,
        "items": records,
        "resource_bundles": resource_bundles,
        "findings": findings,
        "notes": notes,
        "not_assessed": NOT_ASSESSED,
    }


# --- Output ----------------------------------------------------------------------

REQUIREMENT_LABELS = {"team": "team", "certificate": "dev-cert", "cdhash-only": "CDHASH",
                      "apple-generic-only": "ANY-APPLE", "unanchored": "UNANCHORED",
                      "missing": "MISSING", "apple-platform": "APPLE"}


def _cell(value, width):
    value = str(value)
    if len(value) > width:
        value = "..." + value[-(width - 3):]
    return value.ljust(width)


def render(report):
    columns = (("ITEM", 40), ("KIND", 16), ("TEAM", 11), ("RUNTIME", 7), ("TIMESTAMP", 9),
               ("GET-TASK", 8), ("REQUIREMENT", 11), ("VERIFY", 6), ("RESULT", 6))
    lines = ["Signature audit: %s" % report["app"],
             "Configuration: %s%s; expected team: %s" % (
                 report["configuration"], ", distribution" if report["distribution"] else "",
                 report["expected_team"] or "none"),
             "",
             " ".join(_cell(name, width) for name, width in columns).rstrip(),
             " ".join("-" * width for _, width in columns)]
    for record in report["items"]:
        severities = {finding["severity"] for finding in record["findings"]}
        result = "FAIL" if "failure" in severities else "WARN" if "warning" in severities else "ok"
        if record["hardened_runtime"]:
            runtime = "yes"
        else:
            runtime = "NO" if record["hardened_runtime_required"] else "n/a"
        name = Path(report["app"]).name if record["path"] == "." else record["path"]
        values = (name, record["kind"], record["team_identifier"] or "NONE", runtime,
                  "yes" if record["secure_timestamp"] else "no",
                  "YES" if record["entitlements"].get(GET_TASK_ALLOW) is True else "no",
                  REQUIREMENT_LABELS.get(record["requirement_anchor"]["anchor"], "?"),
                  "ok" if record["verify"]["passed"] else "FAIL", result)
        lines.append(" ".join(_cell(value, width) for value, (_, width) in zip(values, columns)).rstrip())
    if report["resource_bundles"]:
        lines += ["", "Resource-only bundles (no executable; sealed by the app): %d" % len(report["resource_bundles"])]
    grouped = {}
    for finding in report["findings"]:
        if finding["severity"] == "info":
            continue
        key = (finding["severity"], finding["check"], finding["detail"])
        grouped.setdefault(key, []).append(finding["path"])
    if grouped:
        lines += ["", "Findings:"]
        for (severity, check, detail), paths in sorted(grouped.items(), key=lambda entry: entry[0][0] != "failure"):
            label = "FAIL" if severity == "failure" else "WARN"
            where = ", ".join(Path(report["app"]).name if path == "." else path for path in paths)
            lines.append("  %s %s [%s]: %s" % (label, check, where, detail.splitlines()[0] if detail else ""))
    for note in report["notes"]:
        lines += ["", "Note: " + note]
    lines += ["", "Result: %s (%d failures, %d warnings)" % (
        "PASS" if report["passed"] else "FAIL", report["failure_count"], report["warning_count"])]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("artifact", type=Path, help="Built .app or .xcarchive (read only).")
    parser.add_argument("--configuration", choices=("release", "debug"), default="release",
                        help="Build configuration being audited (default release). Debug downgrades "
                             "get-task-allow to a warning and records debug-only artifacts as "
                             "expected (info, not counted).")
    parser.add_argument("--distribution", action="store_true",
                        help="Require Developer ID Application authority, secure timestamps and a "
                             "team (subject.OU) requirement on every item.")
    parser.add_argument("--team", help="Expected TeamIdentifier (default: the app's own).")
    parser.add_argument("--json", dest="json_path",
                        help="Write the JSON report to this new file (never overwrites), or - for stdout.")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("Run on macOS with Xcode command line tools installed.")
    if args.distribution and args.configuration != "release":
        parser.error("--distribution audits a Release build only.")
    if args.team and not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("--team must be a ten-character Team ID.")
    if args.json_path not in (None, "-") and os.path.lexists(Path(args.json_path).expanduser()):
        # Checked before the audit, which can take minutes; the final write still never overwrites.
        parser.error("%s already exists; reports are never overwritten." % args.json_path)
    try:
        report = audit(args.artifact, args.configuration, args.distribution, args.team)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    table = render(report)
    if args.json_path == "-":
        sys.stderr.write(table)
        sys.stdout.write(encoded)
    else:
        sys.stdout.write(table)
        if args.json_path:
            with Path(args.json_path).expanduser().open("x", encoding="utf-8") as destination:
                destination.write(encoded)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
