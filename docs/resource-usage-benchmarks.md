# Resource usage measurements, October 7, 2026

The source candidate reduces repeated reader and provider work. These sequential
measurements compare main `0acab4c` with this candidate in the same local
environment using signed installed providers. Hardware, operating-system, and
installed-provider versions are deliberately omitted. The measurements establish
reader-level results, not an overall app memory,
energy, temperature, or long-duration residency improvement.

## Results

Values are medians. CPU is the measured parent process; child CPU is reported
separately. Three fresh processes per revision ran the same ordered scenarios,
baseline then candidate. Warm history has six samples; status and SQLite each
have nine; other rows have three.

| Scenario | Wall time, baseline → candidate | Parent CPU, baseline → candidate | Observed result |
| --- | --- | --- | --- |
| 8 MiB history, cold reader | 1.548 s → 0.758 s | 1.541 s → 0.756 s | One inspected session in both; end footprint 144.3 → 34.0 MiB. |
| 8 MiB history, unchanged reader | 1.526 s → 1.09 ms | 1.521 s → 1.09 ms | Same session coverage; end footprint 28.5 → 34.3 MiB. |
| 20 MiB history, cold reader | 0.54 ms → 0.996 s | 0.55 ms → 0.993 s | Baseline silently inspected zero sessions; candidate inspects one and reports partial coverage. These are unequal correctness outcomes, not a speed comparison. |
| 20 MiB history, unchanged reader | 0.28 ms → 1.14 ms | 0.28 ms → 1.15 ms | Candidate reuses its partial result; end footprint 49.3 → 76.2 MiB. |
| 10,000 storage files, initial | 64.31 ms → 57.92 ms | 64.04 ms → 57.70 ms | Same byte total, no truncation. |
| Storage at logical +120 s | 51.71 ms → 0.14 ms | 51.46 ms → 0.14 ms | Candidate reuses the original measurement. |
| Storage at logical +300 s | 53.51 ms → 0.11 ms | 53.40 ms → 0.11 ms | Candidate reuses the original measurement. |
| 50,000 sessions / two million SQLite log rows | 286.83 ms → 287.34 ms | 4.21 ms → 4.70 ms | Five SQLite launches each; all sessions, zero query errors. Median child CPU 272.81 → 273.10 ms. |
| Installed managed + official statuses | 592.91 ms → 310.99 ms | 1.235 s → 0.660 s | `ps` launches 4 → 2; full validator entries 2 → 1; interrupt wakeups 41 → 20. |
| Live quota display + inventory, same home | 1.521 s → 1.736 s | 2.179 s → 1.195 s | Two successful subscribers; app-server launches and full validator entries 2 → 1. |
| Missing providers | 176.87 ms → 0.27 ms | 27.02 ms → 0.27 ms | `ps` launches 2 → 0; no provider is launched. |

Quota wall latency increased in this run despite fewer launches and lower CPU:
baseline samples ranged 1.446–1.583 s; candidate 1.537–1.804 s. Interrupt wakeups
increased 15 → 99, and end footprint increased 37.7 → 42.6 MiB. Live service
latency and process scheduling vary; no quota latency or universal wakeup
improvement is claimed. Installed status end footprint also increased
30.7 → 35.0 MiB. SQLite candidate wall samples ranged 0.282–0.462 s versus
baseline 0.283–0.293 s; this small sample does not establish tail-latency parity.
It demonstrated no errors/timeouts and an essentially unchanged median, so it
does not justify changing provider-owned indexes or schema.

## Method and bounds

[`benchmark_resources.sh`](../script/benchmark_resources.sh) builds both core
revisions with `swiftc -O -whole-module-optimization`. Temporary source copies
receive identical counters at successful child launches and full validator
entry. Production parsing, filesystem, signature, contract, and process checks
remain active. Synthetic files and databases are real; no mocks or stubs are
used. SQLite fixture creation is outside measured intervals.

“Cold” means an empty scanner cache with freshly written files. OS filesystem
pages are warm; this is not physical cold-disk evidence. Storage timestamps
advance logically without waiting five minutes. The fixture repeats one session
ID to isolate large-history parsing; it does not represent every account's
session distribution. Status reads use signed installed providers and synthetic
managed profile paths, without starting/stopping desktop applications. The
opt-in quota case reads the signed-in native service but emits only successful
read counts and resource counters. It excludes account identity and quota data.

`proc_pid_rusage` supplies process CPU, interrupt/package wakeups, disk counters,
and end-of-interval physical footprint. CPU counters are Mach absolute ticks,
converted using `mach_timebase_info` before emission; the device timebase is
not retained in the receipt. Parent CPU can exceed wall time through parallel threads.
Footprint is an end sample, not peak RSS; scenarios run in sequence and retain
earlier caches. No overall RAM reduction follows from it. Disk counters were
zero in this publication run and exclude some metadata and child I/O; they do
not prove absence of filesystem work. Network-byte attribution is unavailable.
System-wide `powermetrics` required superuser access and was not performed.

The [count-only JSON receipt](benchmarks/resource-usage-2026-10-07.json) contains
all 102 interval records plus the native lifecycle trace. Reproduce with:

```bash
./script/benchmark_resources.sh 0acab4c /tmp/agentdock-resource-results
AGENTDOCK_BENCHMARK_LIVE_QUOTA=1 ./script/benchmark_resources.sh 0acab4c /tmp/agentdock-resource-live-results
```

## Native lifecycle evidence

The bundled [self-contained probe](../script/probe_application_lifecycle.swift)
uses the original scene-phase gate and the production application monitor. It
exercised foreground, two windows, closing one window, hiding/returning, closing
all windows, reopening, and thirty rapid hide/return transitions. Closing all
windows reproduced `application_active=true`, `visible_windows=0`,
`scene_gate=true`, `native_gate=false`. The new gate also follows actual native
focus when a reopened window has not yet activated.

ScreenCaptureKit stream creation failed, so there is no captured full UI proof.
Actual system sleep/wake, prolonged multi-account/window activity, native
notification actions/queue replenishment, and app thermal/energy behavior remain
runtime acceptance gates. See the [finding ledger](resource-usage-qa.md).
