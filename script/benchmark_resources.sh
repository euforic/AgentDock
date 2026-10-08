#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
baseline_ref="${1:-0acab4c}"
output_dir="${2:?Pass an output directory outside the repository}"
mkdir -p "$output_dir"
benchmark_tmp="$(mktemp -d /tmp/agentdock-resource-benchmark.XXXXXX)"
trap 'rm -rf "$benchmark_tmp"' EXIT
mkdir -p "$benchmark_tmp/baseline" "$benchmark_tmp/candidate"
git archive "$baseline_ref" Sources/CodexerCore | tar -x -C "$benchmark_tmp/baseline"
cp -R Sources "$benchmark_tmp/candidate/"
# Identical count-only instrumentation in temporary copies. No commands,
# paths, credentials, accounts, or provider output are recorded.
python3 - "$benchmark_tmp" <<'PY'
from pathlib import Path
import sys
for variant in ['baseline', 'candidate']:
    root = Path(sys.argv[1]) / variant / 'Sources/CodexerCore'
    for name, marker in [('GroupedSubprocess.swift', '        processID = spawnedProcessID'),
                         ('BoundedSubprocess.swift', '        let capture = BoundedDataCapture')]:
        path = root / name
        text = path.read_text()
        assert marker in text
        path.write_text(text.replace(marker, '        ResourceBenchmarkCounters.launched(executableURL.lastPathComponent)\n' + marker, 1))
    path = root / 'ProfileStats.swift'
    text = path.read_text()
    assert '            try process.run()' in text
    path.write_text(text.replace('            try process.run()', '            try process.run()\n            ResourceBenchmarkCounters.launched(sqliteExecutable.lastPathComponent)', 1))
    for name, marker in [('DesktopAppRegistry.swift', '    public func validateApp(at url: URL, product: DesktopProduct) throws {'),
                         ('CodexLauncher.swift', '    public func validateCodexApp(at url: URL) throws {')]:
        path = root / name
        text = path.read_text()
        assert marker in text
        path.write_text(text.replace(marker, marker + '\n        ResourceBenchmarkCounters.validated()', 1))
PY
for variant in baseline candidate; do
    sources=("$benchmark_tmp/$variant/Sources/CodexerCore/"*.swift)
    flags=(-D BASELINE)
    if [[ "$variant" == candidate ]]; then flags=(-D CANDIDATE); fi
    swiftc -O -whole-module-optimization -parse-as-library -module-name CodexerCore "${flags[@]}" "${sources[@]}" script/benchmark_resources.swift -o "$benchmark_tmp/$variant/benchmark"
done
# Sequential processes: same installed providers, fresh identical synthetic
# fixtures each run. Do not launch/close provider applications during these runs.
for repetition in 1 2 3; do
    "$benchmark_tmp/baseline/benchmark" > "$output_dir/baseline-$repetition.jsonl"
    "$benchmark_tmp/candidate/benchmark" > "$output_dir/candidate-$repetition.jsonl"
done
