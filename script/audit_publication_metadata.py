#!/usr/bin/env python3
"""Reject private commit identities and machine/account metadata in receipts."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def git(*arguments):
    return subprocess.check_output(["git", *arguments], text=True).strip()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--all-history", action="store_true",
                    help="also reject private identities in every reachable commit")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)

base = os.environ.get("GITHUB_BASE_REF")
if args.all_history:
    revisions = ["--all"]
elif base:
    revisions = [f"origin/{base}..HEAD"]
else:
    revisions = ["-1", "HEAD"]

errors = []
for line in git("log", "--format=%h%x09%ae%x09%ce", *revisions).splitlines():
    commit, author, committer = line.split("\t")
    for email in (author, committer):
        if email != "noreply@github.com" and not email.endswith("@users.noreply.github.com"):
            errors.append(f"Private email in commit metadata: {commit} (value redacted)")

receipt_keys = {"baseline", "candidate", "repetitions", "cpu_units", "records", "lifecycle_probe"}
record_keys = {
    "scenario", "variant", "repetition", "wall_seconds", "cpu_seconds", "child_cpu_seconds",
    "physical_footprint_bytes", "interrupt_wakeups", "package_idle_wakeups",
    "disk_read_bytes", "disk_write_bytes", "child_launches", "validation_calls",
    "sessions", "partial_messages", "bytes", "truncated", "query_errors",
    "managed_results", "official_results", "successful_reads", "coalesced_batches", "account_reads",
}
trace_keys = {"event", "application_active", "visible_windows", "scene_gate", "native_gate"}
scenario = re.compile(
    r"(?:history-(?:8|20)MiB-(?:cold|warm)|storage-10000-files-(?:0|120|300)s|"
    r"sqlite-50000-sessions-2M-logs-[0-2]|installed-status-[0-2]|"
    r"live-quota-display-and-inventory|missing-provider-status)"
)
events = {"native-change", "scene-task", "scene-change", "foreground", "multiple-windows",
          "one-window-remaining", "hidden", "returned", "closed-all", "reopened", "rapid-switch-complete"}
for path in (root / "docs/benchmarks").glob("resource-usage-*.json"):
    receipt = json.loads(path.read_text())
    if set(receipt) - receipt_keys:
        errors.append(f"Unexpected publication metadata in {path.name}")
    for record in receipt.get("records", []):
        if set(record) - record_keys:
            errors.append(f"Unexpected reader metadata in {path.name}")
        if not scenario.fullmatch(record.get("scenario", "")) or record.get("variant") not in {"baseline", "candidate"}:
            errors.append(f"Unexpected reader label in {path.name}")
        for key, value in record.items():
            if key not in {"scenario", "variant", "child_launches"} and not isinstance(value, (int, float, bool)):
                errors.append(f"Non-numeric measurement in {path.name}")
        if not set(record.get("child_launches", {})) <= {"ps", "sqlite3", "codex"}:
            errors.append(f"Unexpected child executable identifier in {path.name}")
        if any(not isinstance(count, int) for count in record.get("child_launches", {}).values()):
            errors.append(f"Non-numeric child count in {path.name}")
    for record in receipt.get("lifecycle_probe", []):
        if set(record) - trace_keys:
            errors.append(f"Unexpected lifecycle metadata in {path.name}")
        if record.get("event") not in events:
            errors.append(f"Unexpected lifecycle label in {path.name}")
        if any(not isinstance(value, (int, bool)) for key, value in record.items() if key != "event"):
            errors.append(f"Non-numeric lifecycle measurement in {path.name}")

if errors:
    for error in sorted(set(errors)):
        print(error)
    raise SystemExit(1)
print("Publication metadata audit passed.")
