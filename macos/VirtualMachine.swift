import Foundation
import Darwin
import AppKit

struct MachineConfiguration: Codable {
    let id: String
    let name: String
    let cpus: Int
    let memoryMiB: Int
    let disk: String
    let firmware: String
    let variables: String
    let mac: String
    let guestPort: UInt16
    let token: String
}

@MainActor
final class VirtualMachineController {
    let directory: URL
    let runtime: URL
    let configuration: MachineConfiguration
    private var machine: Process?
    private var tpm: Process?
    let controlSocket: String

    init(directory: URL, runtime: URL) throws {
        self.directory = directory
        self.runtime = runtime
        configuration = try JSONDecoder().decode(MachineConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("machine.json")))
        controlSocket = "/tmp/perpendicular-\(getuid())-\(configuration.id.prefix(8)).sock"
    }

    var isRunning: Bool {
        if machine?.isRunning == true { return true }
        return (try? MachineControl.execute(socket:controlSocket,operation:"query-uuid")["UUID"] as? String) == configuration.id
    }

    func shutdown() throws {
        guard isRunning else { return }
        _ = try MachineControl.execute(socket:controlSocket,operation:"system_powerdown")
    }

    func showDesktop() throws {
        if !isRunning {try start()}
        let path=directory.appendingPathComponent("qemu-system-aarch64.pid")
        guard let text=try? String(contentsOf:path,encoding:.utf8),let pid=Int32(text),
              let application=NSRunningApplication(processIdentifier:pid) else {return}
        application.unhide();application.activate(options:[])
    }

    func start() throws {
        guard !isRunning else { return }
        let vm = directory.appendingPathComponent("Windows")
        let tpmSocket = "/tmp/perpendicular-tpm-\(getuid())-\(configuration.id.prefix(8)).sock"
        try? FileManager.default.removeItem(atPath: controlSocket)
        try? FileManager.default.removeItem(atPath: tpmSocket)
        tpm = try launch("swtpm", ["socket", "--tpm2", "--tpmstate", "dir=\(vm.path)/tpm",
            "--ctrl", "type=unixio,path=\(tpmSocket)", "--flags", "not-need-init"], log: "tpm.log")
        // The TPM creates its socket before the VM can attach to it.
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: tpmSocket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: tpmSocket) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The virtual TPM did not start."])
        }
        func block(_ object: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        let c = configuration
        let arguments = [
            "-name", "Perpendicular Windows", "-uuid", c.id,
            "-machine", "virt,gic-version=3,highmem=on,pflash0=code,pflash1=vars",
            "-accel", "hvf", "-cpu", "host", "-smp", String(c.cpus), "-m", String(c.memoryMiB),
            "-nodefaults", "-vga", "none", "-device", "ramfb",
            "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
            "-device", "usb-tablet,bus=xhci.0", "-device", "virtio-rng-pci",
            "-netdev", "user,id=net", "-device", "virtio-net-pci,netdev=net,romfile=,mac=\(c.mac)",
            "-blockdev", block(["driver":"file","node-name":"code-file","filename":c.firmware,"read-only":true]),
            "-blockdev", block(["driver":"raw","node-name":"code","file":"code-file","read-only":true]),
            "-blockdev", block(["driver":"file","node-name":"vars-file","filename":c.variables]),
            "-blockdev", block(["driver":"raw","node-name":"vars","file":"vars-file"]),
            "-blockdev", block(["driver":"file","node-name":"disk-file","filename":c.disk]),
            "-blockdev", block(["driver":"qcow2","node-name":"disk","file":"disk-file"]),
            "-device", "nvme,drive=disk,serial=perpendicular,bootindex=1",
            "-drive", "if=none,id=bootstrap,media=cdrom,readonly=on",
            "-device", "usb-bot,id=usbcd,bus=xhci.0", "-device", "scsi-cd,drive=bootstrap,bus=usbcd.0",
            "-chardev", "socket,id=tpmchar,path=\(tpmSocket)", "-tpmdev", "emulator,id=tpm,chardev=tpmchar",
            "-device", "tpm-tis-device,tpmdev=tpm,ppi=off",
            "-display", "cocoa,show-cursor=on", "-qmp", "unix:\(controlSocket),server=on,wait=off",
            "-monitor", "none", "-serial", "file:\(directory.path)/serial.log", "-rtc", "base=localtime"
        ]
        machine = try launch("qemu-system-aarch64", arguments, log: "qemu.log")
        let companion=tpm
        machine?.terminationHandler={_ in if companion?.isRunning==true{companion?.terminate()}}
        let readyDeadline=Date().addingTimeInterval(4)
        while Date()<readyDeadline {
            if machine?.isRunning != true {
                if tpm?.isRunning==true{tpm?.terminate()}
                throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"Windows could not start. See qemu.log in the machine folder."])
            }
            if FileManager.default.fileExists(atPath:controlSocket){return}
            Thread.sleep(forTimeInterval:0.03)
        }
        throw CocoaError(.executableNotLoadable,userInfo:[NSLocalizedDescriptionKey:"The Windows console did not become ready."])
    }

    private func launch(_ name: String, _ arguments: [String], log: String) throws -> Process {
        let process = Process()
        process.executableURL = name=="qemu-system-aarch64" ? runtime.deletingLastPathComponent().appendingPathComponent("Windows Console.app/Contents/MacOS/qemu-system-aarch64") : runtime.appendingPathComponent(name)
        process.arguments = arguments
        let logURL = directory.appendingPathComponent(log)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions:0o600])
        }
        let output = try FileHandle(forWritingTo: logURL)
        try output.seekToEnd()
        process.standardOutput = output; process.standardError = output
        try process.run()
        try Data(String(process.processIdentifier).utf8).write(to: directory.appendingPathComponent(name + ".pid"), options: .atomic)
        return process
    }
}
