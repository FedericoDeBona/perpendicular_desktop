#!/usr/bin/env python3
"""Bounded per-process GPU observation through Apple's Metal System Trace.

Requires Xcode/Instruments. Save traces outside Git: they contain system-wide
process metadata. Reports unions of observed Active intervals, NOT GPU/core
utilization, energy, queued CPU time, or additive per-process percentages.
"""
import argparse
from collections import Counter, defaultdict
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


def union_ns(intervals):
    total, previous_end = 0, 0
    for start, end in sorted(intervals):
        total += max(0, end - max(start, previous_end))
        previous_end = max(previous_end, end)
    return total


def summarize(toc_path, intervals_path):
    toc = ET.parse(toc_path).getroot()
    runs = toc.findall("run")
    if len(runs) != 1:
        raise ValueError("Expected one recording run; do not silently merge runs")
    summary = runs[0].find("info/summary")
    if summary is None or summary.findtext("duration") is None:
        raise ValueError("Recording summary/duration unavailable")
    seconds = float(summary.findtext("duration"))
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError("Missing or invalid recording duration")
    limit = round(seconds * 1_000_000_000)
    root = ET.parse(intervals_path).getroot()
    ids = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}

    def resolve(element):
        if element is None:
            raise ValueError("Missing exported value")
        seen = set()
        while "ref" in element.attrib:
            reference = element.attrib["ref"]
            if reference in seen or reference not in ids:
                raise ValueError("Invalid XML value reference")
            seen.add(reference)
            element = ids[reference]
        return element

    def value(element):
        node = resolve(element)
        return node.text or node.get("fmt", "")

    tables = [t for t in root.findall(".//node")
              if t.find("schema") is not None
              and t.find("schema").get("name") == "metal-gpu-intervals"]
    if len(tables) != 1:
        raise ValueError("Metal GPU interval table missing or ambiguous; no zero inferred")
    table = tables[0]
    columns = {c.findtext("mnemonic"): i for i, c in enumerate(table.find("schema"))}
    required = {"start", "duration", "state", "process", "channel-name", "gpu"}
    if not required <= columns.keys():
        raise ValueError("Unsupported Metal GPU interval schema")
    groups = defaultdict(lambda: {"intervals": [], "channels": defaultdict(list), "rows": 0})
    states = Counter()
    clipped = 0
    for row in table.findall("row"):
        cells = list(row)
        if len(cells) != len(columns):
            raise ValueError("Exported row does not match schema")
        state = value(cells[columns["state"]])
        states[state] += 1
        if state != "Active":
            continue
        start_node, duration_node = (resolve(cells[columns[key]]) for key in ("start", "duration"))
        if start_node.tag != "start-time" or duration_node.tag != "duration":
            raise ValueError("Unsupported timestamp encoding")
        start, duration = int(start_node.text), int(duration_node.text)
        if duration < 0:
            raise ValueError("Negative GPU interval")
        end = start + duration
        bounded = max(0, start), min(limit, end)
        clipped += bounded != (start, end)
        if bounded[1] <= bounded[0]:
            continue
        process = resolve(cells[columns["process"]])
        pid_node = process.find("pid")
        pid = int(value(pid_node)) if pid_node is not None else None
        name = process.get("fmt", "Unattributed") if pid is not None else "Unattributed"
        group = groups[(pid, name)]
        group["intervals"].append(bounded)
        channel = value(cells[columns["gpu"]]), value(cells[columns["channel-name"]])
        group["channels"][channel].append(bounded)
        group["rows"] += 1
    processes = []
    for (pid, name), group in groups.items():
        processes.append({"pid": pid, "name": name, "activeRows": group["rows"],
                          "observedActiveUnionNs": union_ns(group["intervals"]),
                          "channels": [{"gpu": gpu, "channel": channel,
                                        "observedActiveUnionNs": union_ns(intervals)}
                                       for (gpu, channel), intervals in sorted(group["channels"].items())]})
    processes.sort(key=lambda p: p["observedActiveUnionNs"], reverse=True)
    return {"method": "Apple Instruments / Metal System Trace / metal-gpu-intervals",
            "start": summary.findtext("start-date"), "end": summary.findtext("end-date"),
            "durationSeconds": seconds, "instrumentsVersion": summary.findtext("instruments-version"),
            "states": dict(states), "clippedRows": clipped, "processes": processes,
            "limits": ["Observed Active GPU intervals, not physical GPU/core utilization or energy.",
                       "Overlapping intervals within a process are merged; process/channel totals are not additive.",
                       "No row means no activity observed in this trace, not proof of universal zero usage.",
                       "WindowServer includes system composition; this does not identify its originating app.",
                       "Short recordings and profiling overhead limit comparisons; validate with an active control."]}


def process_snapshot():
    # No arguments, environment, VM tokens or guest control access.
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True)
    return [{"pid": int(pid), "parent": int(parent), "executable": command}
            for pid, parent, command in (row.strip().split(None, 2) for row in rows.splitlines())]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=10, choices=range(5, 31))
    parser.add_argument("--trace", type=Path, help="Analyze one existing trace instead of recording")
    parser.add_argument("--output-directory", type=Path, required=True, help="New private directory outside Git")
    options = parser.parse_args()
    output = options.output_directory.expanduser().resolve()
    if output.is_relative_to(Path(__file__).resolve().parent.parent):
        parser.error("Save private system-wide recordings outside the repository")
    if output.exists():
        parser.error("Output directory already exists")
    trace = options.trace.expanduser().resolve() if options.trace else output / "gpu.trace"
    if options.trace and not trace.is_dir():
        parser.error("Input trace does not exist")
    os.umask(0o077)
    output.mkdir(mode=0o700)
    snapshots = {}

    def run(arguments, name):
        with (output / name).open("x") as log:
            subprocess.run(["xcrun", "xctrace", *arguments], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=180)

    try:
        if not options.trace:
            snapshots["before"] = process_snapshot()
            print(f"Recording {options.seconds}s; saving may take longer...", flush=True)
            run(["record", "--template", "Metal System Trace", "--all-processes",
                 "--time-limit", f"{options.seconds}s", "--output", str(trace)], "record.log")
            snapshots["after"] = process_snapshot()
        toc, intervals = output / "toc.xml", output / "gpu-intervals.xml"
        run(["export", "--input", str(trace), "--toc", "--output", str(toc)], "export-toc.log")
        run(["export", "--input", str(trace), "--xpath",
             '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]',
             "--output", str(intervals)], "export-gpu.log")
        result = summarize(toc, intervals)
        result.update(trace=str(trace), processSnapshots=snapshots)
        (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
        print(f"Captured {result['durationSeconds']:.3f}s. Observed Active interval union per process:")
        for process in result["processes"]:
            print(f"{process['observedActiveUnionNs'] / 1e6:12.3f} ms  {process['name']}")
        if not result["processes"]:
            print("No Active intervals observed; check recording coverage with an active control.")
        print(f"Not physical GPU utilization; do not sum processes. Private evidence: {output}")
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        (output / "error.txt").write_text(str(error) + "\n")
        print(f"GPU measurement unavailable: {error}. See private logs in {output}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
