# Benchmark opt-ins

Use the **Keystorm Release Benchmarks** scheme with an uninstrumented Release
build. Set the intended variable to `1` in the selected test plan or scheme and
select that workload. Keep unrelated opt-ins disabled.

| Variable | Enabled workload |
| --- | --- |
| `KEYSTORM_RUN_FINISH_LATENCY` | Component Finish latency and qualification |
| `KEYSTORM_RUN_COORDINATOR_LATENCY` | Coordinator Finish passes |
| `KEYSTORM_RUN_GENERATION_COMPARISON` | Guided, source-draft, adaptive and boundary comparisons |
| `KEYSTORM_RUN_STORAGE_SCALING` | Storage scaling measurements |
| `KEYSTORM_RUN_CAPTURE_SMOKE` | Short replay capture and injected recovery tests |
| `KEYSTORM_RUN_CAPTURE_ENDURANCE` | The separate 90-minute replay test |
| `KEYSTORM_RUN_INFERENCE_SOAK` | Resident idle and sustained Clean observation |
| `KEYSTORM_RUN_PHYSICAL_CAPTURE_ROUTE` | Coordinated physical input-change recovery |
| `KEYSTORM_RUN_PHYSICAL_CAPTURE_SLEEP` | Coordinated real sleep/wake recovery |

`KEYSTORM_RUN_FINISH_LATENCY` does not enable generation comparisons, storage,
capture smoke or inference soak. The long capture test uses
`KEYSTORM_CAPTURE_ENDURANCE_FIXTURE_MANIFEST` for its validated natural-speech
fixture. Physical tests require existing microphone permission and the real
coordinated action; injected recovery is a separate test.

All benchmark suites share one process-wide lease, acquired for each enabled
test case. This prevents cross-suite GPU, model and disk contention even under
Run All. It does not coordinate separate test-runner processes or other apps;
qualification still requires an isolated host. Run long workloads separately
because native actions may have a shorter time limit than the test itself.

`BenchmarkTestGateTests/concurrentAndThrowingLeases()` checks concurrent
exclusion and release after failure using a private gate. The lightweight
harness and fake-model tests also hold the shared benchmark lease.
