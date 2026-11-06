# Performance checks

## Measured results

The November 6, 2026 development run used an uninstrumented Release build on an
M5 MacBook Air with 16 GiB, Xcode 27, and the installed pinned speech and text
models. The component test completed 102 functional passes without failures,
including 100 warm measurements:

| Warm component measurement | Observed | Fixed target |
| --- | ---: | ---: |
| Finish to raw, p95 | 205.870 ms | 800 ms |
| Finish to Clean, p50 | 525.191 ms | 700 ms |
| Finish to Clean, p95 | 536.364 ms | 1,500 ms |
| In-memory delivery, p95 | 0.191 ms | 100 ms |

All four budgets passed. The workload uses a synthesized, single-speaker English
fixture of 26 words and 8.009 seconds. It writes audio through the production
segmented writer, then measures saved-audio transcription, Clean, validation,
persistence and in-memory delivery. It excludes microphone hardware, physical
shortcuts, capture drain, HUD paint and insertion into another app. These figures
do not establish latency or recognition quality for every language or recording.

The independent observer recorded 46 samples, all on AC power at nominal thermal
state with Low Power Mode off. Sampled combined app/worker footprint peaked at
3,204 MiB, below the 4,096 MiB target. The warm series reused one worker, one load
per model, one compiled grammar and one retained prompt prefix. Every warm Clean
pass used source-draft verification without fallback. The final app's binary
identity and absence of LLVM profile/coverage sections were checked after testing.

The separate coordinator test completed 23 functional passes. Each preserved all
128,143 source frames and inserted exactly once. Ten warm samples per mode gave:

| Synthetic coordinator measurement | Verbatim | Clean |
| --- | ---: | ---: |
| Start to capture-ready, p95 | 6.189 ms | 7.839 ms |
| Finish to ready, p50 | 266.350 ms | 597.729 ms |
| Finish to ready, p95 | 278.982 ms | 650.365 ms |

This workload feeds synthetic PCM at real-time pace through production capture,
the coordinator, writer drain, inference, validation and persistence. Delivery is
in memory. The coordinator distributions are descriptive diagnostics, separate
from the 100-pass component qualification.

Native UI validation also confirmed the global shortcut, a visible and hittable
HUD over TextEdit, the complete fixture, exact UTF-8 insertion once and a durable
delivery receipt. A launch-only toggle mode made automated key releases
deterministic; saved preferences were unchanged. This establishes functional
delivery, not physical short-tap latency. Short capture and injected route/sleep
recovery tests passed. The selected production correctness checks passed with one
strict expected reproduction of an upstream path disabled in production; the
final benchmark harness selection passed 47/47 cases, and release tooling passed
55 Python tests. These selections are not a claim that the entire project suite
was run.

Actual 90-minute recording, battery drain, physical input switching, sleep/wake
and physical short-tap latency were not measured in this validation scope.
Short observations do not establish sustained memory or thermal behavior.
Earlier instrumented or mixed-condition measurements are not used for a formal
percentage speedup claim.

Raw reports, session snapshots, screenshots and native logs remain local because
they can contain machine paths, device identifiers and captured content.
`Release/Benchmarks/` is excluded from version control. This public summary is
not raw qualification evidence and cannot substitute for the reports required by
the release gate.

## Implemented optimizations

- Adaptive source-draft verification for eligible short Clean requests. The
  pinned Qwen model verifies every proposed token against the grammar-constrained
  target result and stops proposing after the first rejection.
- Reused prompt prefixes and grammar matchers, bounded cache accounting and
  resident model reuse avoid repeated preparation work.
- Incremental preview pacing, durable session deltas and indexed journal replay
  reduce repeated capture and persistence work.
- Idle worker observation follows active work and residency instead of polling
  continuously while idle.

Source-draft admission requires a reused prefix, at most 128 uncached tokens,
bounded source and prompt sizes, and at least 1 GiB of measured headroom against
a conservative 4 GiB ceiling. Typed resource incompatibility discards the private
attempt and retries the existing generation loop once with fresh matcher/cache
state. Cancellation and invalid or incomplete generation do not retry. Existing
output and protected-content checks remain in place.

`transformGenerationMicroseconds` includes matcher checkout/reset and any retry;
complete Finish timing is the unchanged qualification metric. The pinned
upstream structural fast-forward path remains disabled because it omits a
sampled token from model history. Its strict reproduction test is retained.

## Reproduce the component and coordinator measurements

Use native Xcode testing with the **Keystorm Release Benchmarks** scheme and
**My Mac** destination. The benchmark target is separate from Debug-only
correctness fixtures. Both Release test plans explicitly disable code coverage;
do not define `DEBUG` to make Release tests compile. Installed pinned models are
required; the tests never download them.

1. Select the **Keystorm Release Benchmarks** collection plan for 30 warm passes,
   or **Performance Qualification** for 100 warm passes with
   `KEYSTORM_PERF_QUALIFY=1`.
2. Run `FinishLatencyTests/finishPassesAgainstBudgets` separately from other model
   workloads. Preserve its complete JSON and finalized native test result.
3. For coordinator diagnostics, select
   `FinishLatencyTests/syntheticCoordinatorLatency` in a separate action with
   `KEYSTORM_RUN_COORDINATOR_LATENCY=1`. The default is 10 warm passes per mode.
4. Verify the actual report's requested count, qualification flag and output
   destination. A selected plan or successful test action alone is not proof of
   qualification.

The collection and qualification plans write to a temporary benchmark directory;
override `KEYSTORM_FINISH_LATENCY_OUTPUT` to preserve distinct runs.
`KEYSTORM_COORDINATOR_LATENCY_COUNT` and `KEYSTORM_COORDINATOR_LATENCY_OUTPUT`
configure the coordinator series. Cold and prewarmed-first passes remain
separate from warm percentile gates.

The component fixture setup pauses 2 ms per 100 ms audio block. Feed pacing is
recorded in the report and must match between compared runs, even though setup
is outside the Finish timer. Keep hardware, OS, model revisions, fixture,
instrumentation, thermal and power conditions consistent. Close competing
inference workloads. Benchmark suites share a per-process lease, but it cannot
isolate other test-runner processes or apps.

See [benchmark opt-ins](BENCHMARK_OPT_INS.md) for diagnostic, capture, storage,
idle and physical workloads. Long workloads should run separately. Use the
**Keystorm Performance Regression** scheme and **Performance Regression** plan
for Debug correctness tests; those do not supply Release latency evidence.

## Comparison and release qualification

Collect two compatible raw component reports, then run:

```sh
python3 -I Release/compare_performance.py \
  --baseline /path/to/matching-baseline.json \
  --candidate /path/to/candidate.json \
  --output /path/to/comparison.json \
  --qualify
```

The comparator recomputes metrics from complete passes. It rejects incomplete or
failed passes, invalid timing, missing models, Debug builds, fewer than 30 warm
samples, and mismatched hardware, OS, model revisions, fixture hashes or feed
pacing. Qualification requires at least 100 warm samples, the four fixed budgets,
nominal/fair endpoint thermal states, Low Power Mode off, an uninitialized global
hosted workspace and stable warm worker/model residency. Reported budget fields
cannot weaken the targets.

Warm p50/p95 regression allowances use the largest of 10% of the baseline,
twice its interquartile range, and an absolute allowance of 50 ms for inference
or 5 ms for delivery/persistence. Candidate noise does not increase its allowance.
These tolerances do not relax fixed qualification budgets. Exit status is 0 for
a passing comparison, 1 for regression/qualification failure and 2 for invalid
or incomparable evidence. Without `--qualify`, a passing comparison still has
`qualified=false`.

Every input must contain valid binary identity and complete
`buildInstrumentation` evidence. Qualification requires no LLVM profile/coverage
sections. The inspector verifies each Mach-O image and architecture against its
UUID and complete load-command/section structure; the Xcode configuration label
or coverage checkbox alone is insufficient. Never add guessed instrumentation
fields to older reports. A candidate must be no more than seven days old, with
at most five minutes of future clock skew. Baseline conditions must match, though
its app identity and age may differ.

Release preflight independently inventories the selected app and recomputes the
qualification from both raw reports:

```sh
python3 -I Release/preflight.py /path/to/Keystorm.app \
  --performance-baseline /path/to/matching-baseline.json \
  --performance-candidate /path/to/candidate.json \
  --output /path/to/new-release-preflight.json
```

The candidate's complete binary identity must match the selected app or archive.
Re-signing can preserve that identity; rebuilding or changing embedded code needs
new candidate evidence. This identifies executable code and bundle version, not
every app resource. Missing, stale, failed, incomparable or mismatched evidence
fails the overall gate, including in development identity mode. A saved
comparison or a report's `qualified` flag cannot replace the raw reports.

Run the offline tooling tests with:

```sh
python3 -m unittest discover -s Release -p 'test_*.py'
```

## Additional resource and storage checks

`Release/soak.py` observes an existing app workload; it does not create a
recording. Preserve CPU, physical footprint, disk I/O, energy, power and thermal
samples separately from latency reports. Resource targets are 4 GiB combined
footprint, a 6 GiB hard limit and at most 128 MiB growth after warm-up. Kernel
energy estimates are not measured battery drain, and sampled peaks are not
continuous maxima.

Accelerated storage tests have covered 90-minute, two-hour and eight-hour
metadata backlogs with durable reopen and reference-replay checks. They do not
represent hours of audio capture. Indexed replay improves reopen work, while
full-history immutability validation retains O(n) work per update; persistence
is not claimed to have constant cost. Real recording endurance, audio continuity,
physical recovery and battery behavior require their own measurements.
