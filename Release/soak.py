#!/usr/bin/env python3
"""Observe a running Keystorm process during a long-session (soak) run.

Usage: python3 -I Release/soak.py --preset 90m --output-dir ~/Keystorm-soak/90m
       python3 -I Release/soak.py --pid 12345 --duration 2h --interval 5 --output-dir ...
       caffeinate -i python3 -I Release/soak.py --preset 8h --label "8 h recording" --output-dir ...

At a fixed interval it samples the app process and its inference-worker children
(children running the same executable): memory footprint (the figure Activity Monitor
shows as Memory), resident size, CPU, the kernel's per-process energy estimate and
disk I/O, plus the system thermal state, Low Power Mode, power source, battery charge,
free-memory level and swap use. It writes samples.csv and processes.csv row by row and
rewrites summary.json atomically every few minutes and at the end, so an interrupted
run keeps its data. The output directory must be new or empty (default
~/Keystorm-soak/<UTC time>, outside the repository).

It only observes. It never launches, activates, drives or signals Keystorm, never
reads its windows, text fields or documents, and makes no network requests. Start the
app yourself first, or pass --wait. The budget comparison in the summary describes
this run only: a qualifying run also needs the real recording workload on the reference
machine. CPU 100% means one fully busy core. Memory is sampled, so a spike between two
samples shows only in the per-process lifetime maximum.
"""
import argparse
import csv
import ctypes
import datetime
import errno
import json
import math
import os
from pathlib import Path
import plistlib
import re
import resource
import signal
import subprocess
import sys
import time

BUNDLE_ID = "dev.mitternacht.Keystorm"
PRESETS = {"90m": 90 * 60, "2h": 2 * 3600, "8h": 8 * 3600}
MIB, GIB = 1024 ** 2, 1024 ** 3
# Initial engineering budgets: targets, not results.
PLAN_BUDGETS = {
    "combined_footprint_target_bytes": 4 * GIB,
    "combined_footprint_hard_bytes": 6 * GIB,
    "growth_after_warmup_limit_bytes": 128 * MIB,
    "reference_machine": "M5 MacBook Air, 16 GiB, macOS 27",
}
THERMAL_STATES = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
SAMPLE_COLUMNS = (
    "sample", "utc", "elapsed_s", "sleep_gap_s", "app_pid",
    "app_footprint_bytes", "app_rss_bytes", "app_cpu_percent", "app_lifetime_max_footprint_bytes",
    "app_energy_nj", "app_disk_read_bytes", "app_disk_written_bytes", "app_idle_wakeups",
    "worker_count", "worker_pids", "workers_footprint_bytes", "workers_rss_bytes", "workers_cpu_percent",
    "other_children_footprint_bytes",
    "combined_footprint_bytes", "combined_rss_bytes", "combined_cpu_percent",
    "thermal_state", "low_power_mode", "power_source", "battery_percent", "battery_state",
    "memory_free_percent", "swap_used_bytes",
)
PROCESS_COLUMNS = ("sample", "utc", "pid", "role", "footprint_bytes", "rss_bytes", "cpu_percent",
                   "lifetime_max_footprint_bytes", "energy_nj")
RUSAGE_FIELDS = (
    "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
    "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
    "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
    "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
    "ri_diskio_byteswritten", "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
    "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy",
    "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive", "ri_billed_system_time",
    "ri_serviced_system_time", "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions",
    "ri_cycles", "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
    "ri_runnable_time", "ri_flags", "ri_user_ptime", "ri_system_ptime", "ri_pinstructions",
    "ri_pcycles", "ri_energy_nj", "ri_penergy_nj", "ri_secure_time_in_system",
    "ri_secure_ptime_in_system", "ri_neural_footprint", "ri_lifetime_max_neural_footprint",
    "ri_interval_max_neural_footprint", "ri_conclave_footprint", "ri_page_wait_time_mach",
    "ri_page_cache_hits",
)


class RusageInfo(ctypes.Structure):
    # struct rusage_info_v6 from <sys/resource.h>; v4 is a prefix of it.
    _fields_ = ([("ri_uuid", ctypes.c_uint8 * 16)]
                + [(name, ctypes.c_uint64) for name in RUSAGE_FIELDS]
                + [("ri_reserved", ctypes.c_uint64 * 6)])


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def run(arguments, timeout=15):
    try:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.decode("utf-8", errors="replace") if result.returncode == 0 else ""


class Kernel:
    """Read-only libproc queries; they work for processes owned by the same user."""

    def __init__(self):
        self.libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self.libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.libc.proc_pid_rusage.restype = ctypes.c_int
        self.libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libc.proc_pidpath.restype = ctypes.c_int
        self.libc.mach_absolute_time.restype = ctypes.c_uint64
        timebase = Timebase()
        self.libc.mach_timebase_info(ctypes.byref(timebase))
        self.ns_per_tick = timebase.numer / timebase.denom
        self.flavor = 6
        self.last_errno = 0

    def now_ticks(self):
        return self.libc.mach_absolute_time()

    def rusage(self, pid):
        info = RusageInfo()
        self.last_errno = 0
        for flavor in (self.flavor, 4):
            if self.libc.proc_pid_rusage(pid, flavor, ctypes.byref(info)) == 0:
                self.flavor = flavor
                break
            self.last_errno = ctypes.get_errno()
            if self.last_errno != errno.EINVAL:
                return None
        else:
            return None
        return {
            "start": info.ri_proc_start_abstime,
            # CPU times are Mach ticks on Apple silicon, not nanoseconds.
            "cpu_ns": (info.ri_user_time + info.ri_system_time) * self.ns_per_tick,
            "footprint": info.ri_phys_footprint,
            "rss": info.ri_resident_size,
            "lifetime_max_footprint": info.ri_lifetime_max_phys_footprint,
            "energy_nj": info.ri_energy_nj if self.flavor == 6 else None,
            "disk_read": info.ri_diskio_bytesread,
            "disk_written": info.ri_diskio_byteswritten,
            "idle_wakeups": info.ri_pkg_idle_wkups,
        }

    def path(self, pid):
        buffer = ctypes.create_string_buffer(4096)
        length = self.libc.proc_pidpath(pid, buffer, ctypes.sizeof(buffer))
        return buffer.raw[:length].decode("utf-8", errors="replace") if length > 0 else None


class SystemProbe:
    """System-wide power, thermal and memory state; all read-only."""

    def __init__(self):
        self._process_info = None
        try:
            objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
            ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
            objc.objc_getClass.restype = ctypes.c_void_p
            objc.objc_getClass.argtypes = [ctypes.c_char_p]
            objc.sel_registerName.restype = ctypes.c_void_p
            objc.sel_registerName.argtypes = [ctypes.c_char_p]

            def send(restype):
                # objc_msgSend must be called through a prototype matching each method.
                return ctypes.CFUNCTYPE(restype, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))

            cls = objc.objc_getClass(b"NSProcessInfo")
            if cls:
                self._process_info = send(ctypes.c_void_p)(cls, objc.sel_registerName(b"processInfo"))
                self._long = send(ctypes.c_long)
                self._bool = send(ctypes.c_bool)
                self._thermal = objc.sel_registerName(b"thermalState")
                self._low_power = objc.sel_registerName(b"isLowPowerModeEnabled")
        except (OSError, AttributeError):
            self._process_info = None

    def thermal_state(self):
        if not self._process_info:
            return "unavailable"
        return THERMAL_STATES.get(self._long(self._process_info, self._thermal), "unknown")

    def low_power_mode(self):
        if not self._process_info:
            return None
        return bool(self._bool(self._process_info, self._low_power))

    def power(self):
        return parse_pmset_batt(run(["/usr/bin/pmset", "-g", "batt"]))

    def memory(self):
        return parse_sysctl_memory(run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_level", "vm.swapusage"]))


def parse_pmset_batt(output):
    source = re.search(r"Now drawing from '([^']+)'", output)
    battery = re.search(r"(\d+)%;\s*([^;]+);", output)
    names = {"AC Power": "ac", "Battery Power": "battery", "UPS Power": "ups"}
    return {"power_source": names.get(source.group(1), source.group(1)) if source else "unknown",
            "battery_percent": int(battery.group(1)) if battery else None,
            "battery_state": battery.group(2).strip() if battery else None}


def parse_sysctl_memory(output):
    lines = output.strip().splitlines()
    free = int(lines[0]) if lines and lines[0].strip().isdigit() else None
    used = re.search(r"used\s*=\s*([\d.]+)([KMGT])", output)
    scale = {"K": 1024, "M": MIB, "G": GIB, "T": 1024 * GIB}
    return {"memory_free_percent": free,
            "swap_used_bytes": int(float(used.group(1)) * scale[used.group(2)]) if used else None}


def parse_duration(value, allow_zero=False):
    if value in PRESETS:
        return float(PRESETS[value])
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([smh]?)", value.strip())
    if not match:
        raise ValueError("%r: use seconds or a number with s, m or h, e.g. 90m." % value)
    seconds = float(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]
    if seconds < 0 or (seconds == 0 and not allow_zero):
        raise ValueError("%r: the duration must be positive." % value)
    return seconds


def process_table():
    rows = []
    for line in run(["/bin/ps", "-axo", "pid=,ppid=,comm="]).splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def app_bundle(executable):
    path = Path(executable)
    if path.parent.name == "MacOS" and path.parent.parent.name == "Contents" and path.parents[2].suffix == ".app":
        return path.parents[2]
    return None


def read_info(bundle, cache):
    if bundle not in cache:
        try:
            cache[bundle] = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
        except (OSError, ValueError, plistlib.InvalidFileException):
            cache[bundle] = {}
    return cache[bundle]


def find_apps(bundle_id, table, path_of, cache):
    """PIDs of app processes with this bundle ID. Workers (children running the same
    executable) are excluded."""
    matches = {}
    for pid, ppid, comm in table:
        if ".app/Contents/MacOS/" not in comm:
            continue
        executable = path_of(pid) or comm
        bundle = app_bundle(executable)
        if bundle and read_info(bundle, cache).get("CFBundleIdentifier") == bundle_id:
            matches[pid] = (ppid, executable)
    return sorted(pid for pid, (ppid, executable) in matches.items()
                  if matches.get(ppid, (None, None))[1] != executable)


def children(app_pid, app_executable, table, path_of):
    found = []
    for pid, ppid, _ in table:
        if ppid == app_pid:
            found.append((pid, "worker" if path_of(pid) == app_executable else "child"))
    return found


# --- Summary --------------------------------------------------------------------

def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    # Nearest-rank: the smallest value with at least this fraction of samples at or below it.
    index = max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def stats(values):
    present = [value for value in values if value is not None]
    if not present:
        return None
    return {"count": len(present), "min": min(present), "p50": percentile(present, 0.5),
            "p95": percentile(present, 0.95), "max": max(present),
            "mean": sum(present) / len(present), "first": present[0], "last": present[-1]}


def median(values):
    ordered = sorted(values)
    if not ordered:
        return None
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def slope_per_hour(points):
    if len(points) < 3:
        return None
    mean_x = sum(x for x, _ in points) / len(points)
    mean_y = sum(y for _, y in points) / len(points)
    denominator = sum((x - mean_x) ** 2 for x, _ in points)
    if denominator == 0:
        return None
    return sum((x - mean_x) * (y - mean_y) for x, y in points) / denominator * 3600


def growth_after_warmup(samples, warmup_s, window_s):
    points = [(row["elapsed_s"], row["combined_footprint_bytes"]) for row in samples
              if row["elapsed_s"] >= warmup_s and row["combined_footprint_bytes"] is not None]
    if not points:
        return {"bytes": None, "reason": "No samples after the warmup."}
    # Windows are anchored to the first and last post-warmup samples, so neither is empty
    # even when the interval exceeds the window or sampling paused right after warmup.
    start, end = points[0][0], points[-1][0]
    if end - start < 2 * window_s:
        return {"bytes": None, "slope_bytes_per_hour": slope_per_hour(points),
                "reason": "Run shorter than warmup plus two comparison windows."}
    baseline = median([value for x, value in points if x <= start + window_s])
    final = median([value for x, value in points if x >= end - window_s])
    return {"bytes": final - baseline, "baseline_median_bytes": baseline, "final_median_bytes": final,
            "window_s": window_s, "slope_bytes_per_hour": slope_per_hour(points), "reason": None}


def counter_delta(samples, key):
    """Increase of a cumulative per-process counter across rows of the same app process."""
    present = [row[key] for row in samples if row.get(key) is not None]
    return present[-1] - present[0] if len(present) >= 2 else None


def summarize(samples, meta, interval_s, warmup_s, window_s, workers_seen, worker_energy_nj,
              worker_peaks):
    awake_s = samples[-1]["elapsed_s"] - samples[0]["elapsed_s"] if len(samples) > 1 else 0.0
    combined = [row["combined_footprint_bytes"] for row in samples]
    growth = growth_after_warmup(samples, warmup_s, window_s)
    thermal, sources = {}, {}
    for row in samples:
        thermal[row["thermal_state"]] = thermal.get(row["thermal_state"], 0) + 1
        sources[row["power_source"]] = sources.get(row["power_source"], 0) + 1
    order = ["nominal", "fair", "serious", "critical"]
    worst = max((state for state in thermal if state in order), key=order.index, default=None)
    battery = [row["battery_percent"] for row in samples if row["battery_percent"] is not None]
    energy = counter_delta(samples, "app_energy_nj")
    wakeups = counter_delta(samples, "app_idle_wakeups")
    peak = max((value for value in combined if value is not None), default=None)
    lifetime = max((row["app_lifetime_max_footprint_bytes"] for row in samples
                    if row["app_lifetime_max_footprint_bytes"] is not None), default=None)
    return dict(meta, **{
        "samples": len(samples),
        "interval_s": interval_s,
        "awake_duration_s": round(awake_s, 3),
        "memory": {
            "combined_footprint_bytes": stats(combined),
            "app_footprint_bytes": stats([row["app_footprint_bytes"] for row in samples]),
            "app_rss_bytes": stats([row["app_rss_bytes"] for row in samples]),
            "workers_footprint_bytes": stats([row["workers_footprint_bytes"] for row in samples
                                              if row["worker_count"]]),
            "app_lifetime_max_footprint_bytes": lifetime,
            "worker_lifetime_max_footprint_bytes": max(worker_peaks.values(), default=None),
            "growth_after_warmup": dict(growth, warmup_s=warmup_s),
        },
        "cpu_percent": {
            "app": stats([row["app_cpu_percent"] for row in samples]),
            "combined": stats([row["combined_cpu_percent"] for row in samples]),
        },
        "workers": {
            "distinct_pids": len(workers_seen),
            "max_concurrent": max((row["worker_count"] for row in samples), default=0),
            "samples_with_worker": sum(1 for row in samples if row["worker_count"]),
        },
        "energy": {
            "app_joules": energy / 1e9 if energy is not None else None,
            "app_average_watts": energy / 1e9 / awake_s if energy is not None and awake_s > 0 else None,
            "workers_joules_observed": worker_energy_nj / 1e9 if worker_energy_nj else None,
            "app_idle_wakeups_per_s": wakeups / awake_s if wakeups is not None and awake_s > 0 else None,
            "note": "Kernel per-process energy estimates, not measured battery drain; worker energy covers "
                    "only the span each worker was sampled.",
        },
        "thermal": {"samples_by_state": thermal, "worst": worst},
        "power": {
            "samples_by_source": sources,
            "battery_percent_first": battery[0] if battery else None,
            "battery_percent_last": battery[-1] if battery else None,
            "battery_percent_min": min(battery) if battery else None,
            "low_power_mode_seen": any(row["low_power_mode"] for row in samples),
        },
        "plan_budgets": dict(PLAN_BUDGETS, observed={
            "peak_sampled_combined_footprint_bytes": peak,
            "within_target": peak <= PLAN_BUDGETS["combined_footprint_target_bytes"] if peak is not None else None,
            "within_hard_budget": peak <= PLAN_BUDGETS["combined_footprint_hard_bytes"] if peak is not None else None,
            "growth_within_limit": (growth["bytes"] <= PLAN_BUDGETS["growth_after_warmup_limit_bytes"]
                                    if growth["bytes"] is not None else None),
            "note": "Observation of this run only, not a gate result. Qualification needs the real "
                    "recording workload on the reference machine.",
        }),
    })


# --- Sampling ----------------------------------------------------------------------

def target_identity(app_pid, executable, info):
    bundle = app_bundle(executable)
    signature = {}
    try:
        # codesign prints its display output on stderr.
        result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=2", str(bundle or executable)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60, check=False)
        lines = result.stderr.decode("utf-8", errors="replace").splitlines()
    except (OSError, subprocess.TimeoutExpired):
        lines = []
    for line in lines:
        key, _, value = line.partition("=")
        if key in ("Identifier", "TeamIdentifier", "CDHash") or (key == "Authority" and "authority" not in signature):
            signature[key.lower()] = value.strip()
    return {"pid": app_pid, "executable": executable, "app": str(bundle) if bundle else None,
            "bundle_id": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
            "signature": signature}


def host_identity():
    values = run(["/usr/sbin/sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"]).splitlines()
    return {"model": values[0] if values else None,
            "memory_bytes": int(values[1]) if len(values) > 1 and values[1].isdigit() else None,
            "cpu": values[2] if len(values) > 2 else None,
            "macos": run(["/usr/bin/sw_vers", "-productVersion"]).strip() or None,
            "macos_build": run(["/usr/bin/sw_vers", "-buildVersion"]).strip() or None}


def digest(summary):
    """A few human-readable lines; summary.json holds the full record."""
    def mib(value):
        return "%.0f MiB" % (value / MIB) if value is not None else "n/a"

    memory, cpu = summary["memory"], summary["cpu_percent"]["combined"]
    growth = memory["growth_after_warmup"]
    combined = memory["combined_footprint_bytes"] or {}
    return "\n".join([
        "Combined footprint p50 %s, peak %s (target %s, hard %s)" % (
            mib(combined.get("p50")), mib(combined.get("max")),
            mib(PLAN_BUDGETS["combined_footprint_target_bytes"]), mib(PLAN_BUDGETS["combined_footprint_hard_bytes"])),
        "Growth after warmup: %s" % (mib(growth["bytes"]) if growth["bytes"] is not None else growth["reason"]),
        "Combined CPU p50 %s%%, p95 %s%%" % ((cpu or {}).get("p50"), (cpu or {}).get("p95")),
        "Thermal worst: %s; power sources: %s; system sleep %ss" % (
            summary["thermal"]["worst"], summary["power"]["samples_by_source"], summary["system_sleep_s"]),
    ])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--bundle-id", default=BUNDLE_ID, help="App to observe (default %s)." % BUNDLE_ID)
    target.add_argument("--pid", type=int, help="Observe this process ID instead.")
    length = parser.add_mutually_exclusive_group()
    length.add_argument("--preset", choices=sorted(PRESETS), help="Run length: 90m, 2h or 8h.")
    length.add_argument("--duration", help="Run length, e.g. 45m or 3h. Default: until the app exits or Ctrl-C.")
    parser.add_argument("--interval", type=float, default=10.0, help="Seconds between samples (default 10).")
    parser.add_argument("--warmup", default="10m", help="Excluded from growth comparison (default 10m).")
    parser.add_argument("--window", default="10m", help="Median window for growth comparison (default 10m).")
    parser.add_argument("--summary-every", default="5m", help="Checkpoint summary.json this often (default 5m).")
    parser.add_argument("--wait", default="0", help="Wait this long for the app to start (default 0).")
    parser.add_argument("--label", default="", help="Free text stored in the summary, e.g. the scenario.")
    parser.add_argument("--output-dir", type=Path,
                        help="New or empty directory for the results (default ~/Keystorm-soak/<UTC time>).")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("Run on macOS.")
    try:
        length = args.preset or args.duration
        duration = parse_duration(length) if length else None
        warmup = parse_duration(args.warmup, allow_zero=True)
        window = parse_duration(args.window)
        checkpoint = parse_duration(args.summary_every)
        wait = parse_duration(args.wait, allow_zero=True)
    except ValueError as error:
        parser.error(str(error))
    if not 0.5 <= args.interval <= 600:
        parser.error("--interval must be between 0.5 and 600 seconds.")

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output_dir or Path.home() / "Keystorm-soak" / stamp).expanduser()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("%s exists and is not an empty directory; results are never overwritten." % output)
    kernel, probe, cache = Kernel(), SystemProbe(), {}

    deadline = time.monotonic() + wait
    while True:
        table = process_table()
        if args.pid is not None:
            pids = [args.pid] if kernel.rusage(args.pid) is not None else []
        else:
            pids = find_apps(args.bundle_id, table, kernel.path, cache)
        if pids or time.monotonic() >= deadline:
            break
        time.sleep(min(2.0, max(0.1, deadline - time.monotonic())))
    if not pids and args.pid is not None and kernel.last_errno == errno.EPERM:
        parser.error("Process %d belongs to another user; only your own processes can be observed." % args.pid)
    if not pids:
        parser.error("No running process found (%s). Start the app yourself; this tool never launches it."
                     % ("pid %d" % args.pid if args.pid is not None else args.bundle_id))
    if len(pids) > 1:
        parser.error("Several %s processes are running (PIDs %s); pass --pid."
                     % (args.bundle_id, ", ".join(map(str, pids))))
    app_pid = pids[0]
    executable = kernel.path(app_pid)
    first = kernel.rusage(app_pid)
    if executable is None or first is None:
        parser.error("Cannot read process %d (it must belong to this user)." % app_pid)
    bundle = app_bundle(executable)
    info = read_info(bundle, cache) if bundle else {}

    output.mkdir(parents=True, exist_ok=True)
    samples_file = (output / "samples.csv").open("x", newline="", encoding="utf-8")
    processes_file = (output / "processes.csv").open("x", newline="", encoding="utf-8")
    sample_writer = csv.DictWriter(samples_file, fieldnames=SAMPLE_COLUMNS)
    process_writer = csv.DictWriter(processes_file, fieldnames=PROCESS_COLUMNS)
    sample_writer.writeheader()
    process_writer.writeheader()

    stop = {"reason": None}

    def request_stop(signum, _frame):
        stop["reason"] = "terminated (signal %d)" % signum

    signal.signal(signal.SIGTERM, request_stop)
    if signal.getsignal(signal.SIGHUP) != signal.SIG_IGN:  # Keep running under nohup.
        signal.signal(signal.SIGHUP, request_stop)

    started_wall = time.time()
    started_mono = time.monotonic()
    uptime_s = (kernel.now_ticks() - first["start"]) * kernel.ns_per_tick / 1e9
    meta = {
        "tool": "Release/soak.py", "schema": 1, "label": args.label,
        "started_at": datetime.datetime.fromtimestamp(started_wall, datetime.timezone.utc).isoformat(),
        "requested_duration_s": duration,
        "target": dict(target_identity(app_pid, executable, info), awake_uptime_at_start_s=round(uptime_s, 1)),
        "host": host_identity(),
        "files": {"samples": "samples.csv", "processes": "processes.csv"},
        "not_assessed": ["Recording workload (the owner drives the app)", "Audio fidelity and backlog",
                         "Battery drain attributable to Keystorm alone"],
    }
    samples, previous, workers_seen, worker_first_energy, worker_last_energy, worker_peaks = [], {}, set(), {}, {}, {}
    end_reason, skipped, sleep_total, last_checkpoint = None, 0, 0.0, started_mono
    last_wall, last_mono = started_wall, started_mono

    def write_summary(final):
        if not samples:
            return
        observer = resource.getrusage(resource.RUSAGE_SELF)
        worker_energy = sum(worker_last_energy[pid] - worker_first_energy[pid] for pid in worker_last_energy)
        summary = summarize(samples, meta, args.interval, warmup, window, workers_seen, worker_energy, worker_peaks)
        summary.update({
            "complete": final,
            "ended_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "end_reason": end_reason if final else "running",
            "wall_duration_s": round(time.time() - started_wall, 3),
            "completed_requested_duration": (time.time() - started_wall >= duration - args.interval
                                             if duration is not None else None),
            "system_sleep_s": round(sleep_total, 3),
            "skipped_samples": skipped,
            "observer_cpu_s": round(observer.ru_utime + observer.ru_stime, 3),
        })
        temporary = output / "summary.json.tmp"
        with temporary.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        os.replace(temporary, output / "summary.json")

    def take_sample(index):
        nonlocal sleep_total, last_wall, last_mono
        wall, mono = time.time(), time.monotonic()
        gap = max(0.0, (wall - last_wall) - (mono - last_mono))
        sleep_gap = gap if gap > 2.0 else 0.0
        sleep_total += sleep_gap
        last_wall, last_mono = wall, mono
        utc = datetime.datetime.fromtimestamp(wall, datetime.timezone.utc).isoformat()
        app = kernel.rusage(app_pid)
        if app is None or kernel.path(app_pid) != executable:
            return "process_exited"
        if app["start"] != first["start"]:
            return "process_replaced"
        table = process_table()
        rows = [(app_pid, "app", app)]
        for pid, role in children(app_pid, executable, table, kernel.path):
            usage = kernel.rusage(pid)
            if usage is not None:
                rows.append((pid, role, usage))
        now_ticks = kernel.now_ticks()
        cpu = {}
        for pid, role, usage in rows:
            before = previous.get(pid)
            if before and before[0] == usage["start"]:
                elapsed = (mono - before[2]) * 1e9
                cpu[pid] = (usage["cpu_ns"] - before[1]) / elapsed * 100 if elapsed > 0 else None
            else:
                age = (now_ticks - usage["start"]) * kernel.ns_per_tick
                # A child that started since the last sample: average over its short life.
                cpu[pid] = usage["cpu_ns"] / age * 100 if pid != app_pid and 0 < age <= 2 * args.interval * 1e9 else None
            previous[pid] = (usage["start"], usage["cpu_ns"], mono)
        workers = [(pid, usage) for pid, role, usage in rows if role == "worker"]
        others = [usage for pid, role, usage in rows if role == "child"]
        for pid, usage in workers:
            workers_seen.add(pid)
            worker_peaks[pid] = usage["lifetime_max_footprint"]
            if usage["energy_nj"] is not None:
                worker_first_energy.setdefault(pid, usage["energy_nj"])
                worker_last_energy[pid] = usage["energy_nj"]

        def total(values):
            values = [value for value in values if value is not None]
            return sum(values) if values else None

        worker_cpu = total(cpu.get(pid) for pid, _ in workers) if workers else 0.0
        power, memory = probe.power(), probe.memory()
        row = {
            "sample": index, "utc": utc, "elapsed_s": round(mono - started_mono, 3),
            "sleep_gap_s": round(sleep_gap, 3), "app_pid": app_pid,
            "app_footprint_bytes": app["footprint"], "app_rss_bytes": app["rss"],
            "app_cpu_percent": round(cpu[app_pid], 2) if cpu.get(app_pid) is not None else None,
            "app_lifetime_max_footprint_bytes": app["lifetime_max_footprint"],
            "app_energy_nj": app["energy_nj"], "app_disk_read_bytes": app["disk_read"],
            "app_disk_written_bytes": app["disk_written"], "app_idle_wakeups": app["idle_wakeups"],
            "worker_count": len(workers), "worker_pids": " ".join(str(pid) for pid, _ in workers),
            "workers_footprint_bytes": sum(usage["footprint"] for _, usage in workers),
            "workers_rss_bytes": sum(usage["rss"] for _, usage in workers),
            "workers_cpu_percent": round(worker_cpu, 2) if worker_cpu is not None else None,
            "other_children_footprint_bytes": sum(usage["footprint"] for usage in others),
            "combined_footprint_bytes": app["footprint"] + sum(usage["footprint"] for _, usage in workers),
            "combined_rss_bytes": app["rss"] + sum(usage["rss"] for _, usage in workers),
            "combined_cpu_percent": (round(cpu[app_pid] + (worker_cpu or 0.0), 2)
                                     if cpu.get(app_pid) is not None else None),
            "thermal_state": probe.thermal_state(), "low_power_mode": probe.low_power_mode(),
            "power_source": power["power_source"], "battery_percent": power["battery_percent"],
            "battery_state": power["battery_state"], "memory_free_percent": memory["memory_free_percent"],
            "swap_used_bytes": memory["swap_used_bytes"],
        }
        samples.append(row)
        sample_writer.writerow(row)
        samples_file.flush()
        for pid, role, usage in rows:
            process_writer.writerow({
                "sample": index, "utc": utc, "pid": pid, "role": role, "footprint_bytes": usage["footprint"],
                "rss_bytes": usage["rss"],
                "cpu_percent": round(cpu[pid], 2) if cpu.get(pid) is not None else None,
                "lifetime_max_footprint_bytes": usage["lifetime_max_footprint"], "energy_nj": usage["energy_nj"]})
        processes_file.flush()
        return None

    print("Observing PID %d (%s) every %gs%s. Writing to %s. Ctrl-C ends the run." % (
        app_pid, executable, args.interval,
        " for %gs" % duration if duration else " until the app exits", output), file=sys.stderr)
    index = 0
    try:
        while True:
            end_reason = take_sample(index)
            if end_reason:
                break
            if stop["reason"]:
                end_reason = stop["reason"]
                break
            if duration is not None and time.time() - started_wall >= duration:
                end_reason = "duration_reached"
                break
            if time.monotonic() - last_checkpoint >= checkpoint:
                write_summary(False)
                last_checkpoint = time.monotonic()
            index += 1
            target_time = started_mono + index * args.interval
            if time.monotonic() > target_time + args.interval:
                # Late by more than one interval (slow probe or system sleep): realign.
                missed = int((time.monotonic() - target_time) // args.interval)
                skipped += missed
                index += missed
                target_time = started_mono + index * args.interval
            while not stop["reason"]:
                remaining = target_time - time.monotonic()
                if duration is not None:
                    remaining = min(remaining, duration - (time.time() - started_wall))
                if remaining <= 0:
                    break
                time.sleep(min(1.0, remaining))
    except KeyboardInterrupt:
        end_reason = "interrupted"
    except Exception as error:
        end_reason = "error: %s" % error
        raise
    finally:
        samples_file.close()
        processes_file.close()
        write_summary(True)
    print("%s after %d samples; summary: %s" % (end_reason, len(samples), output / "summary.json"),
          file=sys.stderr)
    if samples:
        print(digest(json.loads((output / "summary.json").read_text(encoding="utf-8"))), file=sys.stderr)
    return 0 if samples else 1


if __name__ == "__main__":
    raise SystemExit(main())
