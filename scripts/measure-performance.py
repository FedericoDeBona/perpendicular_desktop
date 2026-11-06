#!/usr/bin/env python3
"""Bounded, read-only macOS/QMP observation of the running app and VM.

No synthetic workload, disk-image access or guest configuration changes.
CPU is percent of one core; process footprints are not additive physical RAM.
QMP nodes overlap: never sum parent and child byte counters.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import time

LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")

class Usage(ctypes.Structure):
    # rusage_info_v2, from the macOS SDK sys/resource.h. CPU times are Mach ticks.
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idleWakeups", "interruptWakeups", "pageins", "wired",
        "resident", "footprint", "start", "exit", "childUser", "childSystem",
        "childIdle", "childInterrupt", "childPageins", "childElapsed",
        "diskReadBytes", "diskWriteBytes")]


def usage(pid):
    value = Usage()
    if LIBPROC.proc_pid_rusage(pid, 2, ctypes.byref(value)):
        return None
    return {name: getattr(value, name) for name, _ in value._fields_ if name != "uuid"}


def gpu_usage(pids):
    """Optional driver counters, not whole-GPU utilization or energy.

    Registry clients and queue slots must survive both endpoints. The driver
    property is not a stable public timing contract; retain its raw units.
    """
    result = {}
    def visit(entries):
        for entry in entries:
            creator = re.fullmatch(r"pid (\d+), (.*)", entry.get("IOUserClientCreator", ""))
            if creator and int(creator[1]) in pids:
                queues = entry.get("AppUsage")
                if isinstance(queues, list) and all(isinstance(q, dict) and
                        isinstance(q.get("accumulatedGPUTime"), int) and q["accumulatedGPUTime"] >= 0 for q in queues):
                    result[str(entry["IORegistryEntryID"])] = {
                        "pid": int(creator[1]), "queues": queues}
            visit(entry.get("IORegistryEntryChildren", []))
    visit(plistlib.loads(subprocess.check_output(
        ["ioreg", "-a", "-r", "-c", "AGXDeviceUserClient"], timeout=5)))
    return result


class QMP:
    def __init__(self, path, identity, pid):
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(3)
        self.connection.connect(str(path))
        # LOCAL_PEERPID, as in MachineControl.swift; refuse a replaced process.
        peer = int.from_bytes(self.connection.getsockopt(0, 2, 4), "little")
        if peer != pid:
            raise RuntimeError("The QMP process changed")
        self.file = self.connection.makefile("rwb", buffering=0)
        self.file.readline()
        self.call("qmp_capabilities")
        if self.call("query-uuid")["UUID"].lower() != identity.lower():
            raise RuntimeError("QMP belongs to another VM")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.file.close()
        self.connection.close()

    def call(self, command, **arguments):
        self.file.write(json.dumps({"execute": command, "arguments": arguments}).encode() + b"\n")
        while True:
            line = self.file.readline(1_048_576)
            if not line:
                raise RuntimeError("QMP disconnected")
            value = json.loads(line)
            if "error" in value:
                raise RuntimeError(value["error"])
            if "return" in value:
                return value["return"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Perpendicular.app"), help="Frontend bundle to observe")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--seconds", type=int, default=12, choices=range(5, 61))
    parser.add_argument("--output", type=Path, required=True, help="New private JSON file outside Git")
    parser.add_argument("--gpu", action="store_true", help="Include raw per-client AGX GPU counters, when available")
    parser.add_argument("--require-idle", action="store_true", help="Refuse endpoints with Desktop or Seamless windows open")
    options = parser.parse_args()
    if options.output.resolve().is_relative_to(Path(__file__).resolve().parent.parent):
        parser.error("Save private measurements outside the repository")
    if options.output.exists():
        parser.error("The measurement output already exists")
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    timebase = Timebase()
    if ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(timebase)) or not timebase.denom:
        raise RuntimeError("Mach timebase is unavailable")
    tick_ns = timebase.numer / timebase.denom
    root = options.directory
    if root is None:
        info = plistlib.loads((options.app / "Contents/Info.plist").read_bytes())
        root = Path(info.get("PerpendicularMachineDirectory", str(Path.home() / "Library/Application Support/Perpendicular Memory IoT")))
    configuration = json.loads((root / "machine.json").read_text())
    pid = int((root / "qemu-system-aarch64.pid").read_text())
    qmp_path = f"/tmp/perpendicular-{os.getuid()}-{configuration['id'][:8]}.sock"
    processes = []
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True)
    table = [row.strip().split(None, 2) for row in rows.splitlines()]
    family = {pid}
    while True:
        found = family | {int(p) for p, parent, _ in table if int(parent) in family}
        if found == family:
            break
        family = found
    for proc, _, command in table:
        if (int(proc) in family or command == str(options.app.resolve() / "Contents/MacOS/Perpendicular") or
                command.startswith(str(root.resolve() / "Runtimes") + "/") or
                command.startswith(str(root.resolve() / "HostVPN") + "/")):
            processes.append((int(proc), Path(command).name))

    def snapshot():
        def control(command):
            return json.loads(subprocess.check_output([
                "python3", str(Path(__file__).with_name("control_guest.py")),
                "--socket", str(root / "Control/control.sock"), command], text=True))["result"]
        status = control("status")
        if options.require_idle and (not status["connected"] or not status["machineRunning"] or
                status["windowCount"] != 0 or status["desktop"].get("visible") is not False):
            raise RuntimeError("The VM is not connected and idle without Desktop/Seamless windows")
        clock = control("pipeline_clock")
        # Frontend BlockBackend accounting is populated by NVMe. The node
        # variant can return all-zero counters even during real I/O.
        # The monitor accepts one client. Holding it across the sample would
        # block the product's memory controller and invalidate the observation.
        with QMP(qmp_path, configuration["id"], pid) as qmp:
            blocks = qmp.call("query-blockstats")
            try:
                native = json.loads(qmp.call("qom-get", path="/machine/peripheral/display0/virtio-backend", property="perp-live-stats"))
            except (RuntimeError, ValueError, TypeError) as error:
                native = {"unavailable": str(error)}
        gpu = {}
        if options.gpu:
            try:
                gpu = {"clients": gpu_usage({p for p, _ in processes}), "monotonic": time.monotonic()}
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                gpu = {"unavailable": str(error)}
        return {"monotonic": time.monotonic(), "processes": {str(p): usage(p) for p, _ in processes}, "gpu": gpu,
                "blocks": [{k: v for k, v in b.items() if k in ("node-name", "stats")} for b in blocks],
                "memory": status["memory"], "desktop": status["desktop"], "windowCount": status["windowCount"],
                "networkObservation": status.get("networkObservation", {}),
                "catalogue": {key: status.get("launcher", {}).get(key) for key in ("catalogueAutomaticEligible", "catalogueRefreshes")},
                "guestClock": clock,
                "nativeGraphics": native,
                "gpuCache": status["windowGPUCache"],
                "vmStat": subprocess.check_output(["vm_stat"], text=True),
                "swap": subprocess.check_output(["sysctl", "-n", "vm.swapusage"], text=True)}

    before = snapshot()
    time.sleep(options.seconds)
    after = snapshot()
    elapsed = after["monotonic"] - before["monotonic"]
    summary = {"seconds": elapsed, "processes": [], "blocks": []}
    a, b = before["guestClock"]["guest"]["value"], after["guestClock"]["guest"]["value"]
    if a["frequency"] == b["frequency"] and b["qpc"] > a["qpc"] and a["workerCPU100ns"] is not None and b["workerCPU100ns"] is not None and b["workerCPU100ns"] >= a["workerCPU100ns"]:
        guest_seconds = (b["qpc"] - a["qpc"]) / a["frequency"]
        summary["guestWorkerCPUPercentOneCore"] = 100 * (b["workerCPU100ns"] - a["workerCPU100ns"]) / 1e7 / guest_seconds
    for proc, name in processes:
        a, b = before["processes"][str(proc)], after["processes"][str(proc)]
        if a is None or b is None or a["start"] != b["start"]:
            summary["processes"].append({"pid": proc, "name": name, "unavailableOrReplaced": True})
            continue
        row = {"pid": proc, "name": name, "cpuPercentOneCore": 100 * (b["user"] + b["system"] - a["user"] - a["system"]) * tick_ns / 1e9 / elapsed,
               "footprintMiB": [a["footprint"] / 1048576, b["footprint"] / 1048576],
               "residentMiB": [a["resident"] / 1048576, b["resident"] / 1048576]}
        for key in ("idleWakeups", "interruptWakeups", "pageins", "diskReadBytes", "diskWriteBytes"):
            row[key + "Delta"] = b[key] - a[key]
        summary["processes"].append(row)
    if options.gpu:
        a, b = before["gpu"], after["gpu"]
        gpu = {"scope": "raw AGX accumulatedGPUTime; driver units, not total GPU utilization", "clients": []}
        if "clients" in a and "clients" in b:
            gpu["seconds"] = b["monotonic"] - a["monotonic"]
            gpu["clientsAppeared"] = sorted(b["clients"].keys() - a["clients"].keys())
            gpu["clientsDisappeared"] = sorted(a["clients"].keys() - b["clients"].keys())
            for key in a["clients"].keys() & b["clients"].keys():
                old, new = a["clients"][key], b["clients"][key]
                queues = list(zip(old["queues"], new["queues"]))
                prior_process = before["processes"].get(str(old["pid"]))
                next_process = after["processes"].get(str(new["pid"]))
                stable = old["pid"] == new["pid"] and prior_process is not None and next_process is not None and prior_process["start"] == next_process["start"] and len(old["queues"]) == len(new["queues"]) and all(
                    x.get("API") == y.get("API") and y["accumulatedGPUTime"] >= x["accumulatedGPUTime"] for x, y in queues)
                gpu["clients"].append({"client": key, "pid": new["pid"], "stable": stable,
                    "accumulatedGPUTimeDelta": sum(y["accumulatedGPUTime"] - x["accumulatedGPUTime"] for x, y in queues) if stable else None})
        else:
            gpu["unavailable"] = [a.get("unavailable"), b.get("unavailable")]
        summary["gpu"] = gpu
    prior = {b["node-name"]: b["stats"] for b in before["blocks"] if "node-name" in b}
    for block in after["blocks"]:
        name = block.get("node-name")
        if name not in prior:
            continue
        delta = {k: v - prior[name][k] for k, v in block["stats"].items()
                 if k in prior[name] and isinstance(v, int) and not isinstance(v, bool) and k.endswith(("_bytes", "_operations", "_total_time_ns"))}
        summary["blocks"].append({"node": name, "delta": delta})
    result = {"version": 3, "machTimebase": [timebase.numer, timebase.denom], "summary": summary, "before": before, "after": after}
    # Never overwrite an earlier measurement or follow an output symlink.
    fd = os.open(options.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(result, out, indent=2)
    print(json.dumps({"seconds": elapsed, "guestWorkerCPUPercentOneCore": summary.get("guestWorkerCPUPercentOneCore"), "processes": summary["processes"],
                      "disk": [b for b in summary["blocks"] if b["node"] in ("disk", "disk-file")]}, separators=(",", ":")))


if __name__ == "__main__":
    main()
