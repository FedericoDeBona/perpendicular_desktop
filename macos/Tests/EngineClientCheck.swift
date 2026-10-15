import Foundation

/// Compile with PerpendicularDesktop/Engine.swift and run as a standalone executable.
/// Exercises the process/JSON boundary without creating or starting any VM.
@main
@MainActor
struct EngineClientCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perpendicular-client-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("engine-fixture")
        let program = #"""
        #!/bin/sh
        LOCK="$(dirname "$0")/active"
        if ! mkdir "$LOCK" 2>/dev/null; then
          printf '%s\n' '{"error":{"code":"overlap","message":"Engine calls overlapped"}}'
          exit 2
        fi
        trap 'rmdir "$LOCK"' EXIT
        sleep 0.05
        case "$1" in
          list)
            if [ "${PERPENDICULAR_FIXTURE_LIST_ERROR:-0}" = 1 ]; then
              printf '%s\n' '{"error":{"code":"list_failed","message":"Library connection lost."}}'; exit 1
            fi
            printf '%s\n' '{"vms":[{"id":"vm-123","name":"Windows 11","state":"paused","cpus":4,"memory_mib":8192,"disk_gib":80,"iso_path":null,"directory":"/tmp/vm","disk_path":"/tmp/vm/disk.qcow2","created_at":"2026-10-15T10:00:00Z","backend":"qemu-hvf","qmp_socket":"/tmp/qmp","vnc_socket":"/tmp/vnc","last_error":null}]}' ;;
          system-info)
            if [ "${PERPENDICULAR_FIXTURE_SYSTEM_ERROR:-0}" = 1 ]; then
              printf '%s\n' '{"error":{"code":"system_info_failed","message":"System information failed."}}'; exit 1
            fi
            printf '%s\n' '{"architecture":"aarch64","memory_bytes":25769803776,"hypervisor_available":true,"qemu_path":null,"qemu_img_path":null,"firmware_code_path":null,"firmware_vars_path":null,"swtpm_path":null,"data_dir":"/tmp/VMs","firmware_secure_boot_capable":true,"secure_boot_verified":false,"windows_readiness":{"graphics":"Not accelerated","network":"Guest driver required","secure_boot":"guest_verification_required","tpm_available":false}}' ;;
          error) printf '%s\n' '{"error":{"code":"invalid_state","message":"Shut down the virtual machine first."}}'; exit 1 ;;
          malformed) printf '%s\n' 'broken JSON' ;;
          *) printf '%s\n' '{}' ;;
        esac
        """#
        try program.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        setenv("PERPENDICULAR_ENGINE", fixture.path, 1)

        let client = EngineClient()
        async let first: VMListResult = client.execute(["list"])
        async let second: VMListResult = client.execute(["list"])
        let (a, b) = try await (first, second)
        precondition(a.vms.count == 1 && b.vms.count == 1)
        let vm = a.vms[0]
        precondition(vm.id == "vm-123" && vm.memoryMib == 8192 && vm.diskGib == 80)
        precondition(vm.isoPath == nil && vm.state == "paused" && vm.isActive && !vm.isStopped)
        let host: HostInfo = try await client.execute(["system-info"])
        precondition(host.memoryGib == 24 && host.hypervisorAvailable && !host.readyToStart && host.qemuPath == nil)
        precondition(host.firmwareSecureBootCapable == true && host.secureBootVerified == false)
        precondition(host.windowsReadiness?.secureBoot == "guest_verification_required")
        do {
            let _: CommandResult = try await client.execute(["error"])
            fatalError("Nonzero engine status was accepted")
        } catch {
            precondition(error.localizedDescription == "Shut down the virtual machine first.")
        }
        do {
            let _: VMListResult = try await client.execute(["malformed"])
            fatalError("Invalid JSON was accepted")
        } catch {
            precondition(error.localizedDescription.contains("unreadable response"))
        }
        setenv("PERPENDICULAR_FIXTURE_SYSTEM_ERROR", "1", 1)
        let model = LibraryModel()
        await model.load()
        let (hostError, listError, count) = (model.hostError, model.connectionError, model.machines.count)
        precondition(hostError == "System information failed." && listError == nil && count == 1)
        unsetenv("PERPENDICULAR_FIXTURE_SYSTEM_ERROR")
        setenv("PERPENDICULAR_FIXTURE_LIST_ERROR", "1", 1)
        await model.refresh()
        precondition(model.connectionError == "Library connection lost." && !model.canControl && model.machines.count == 1)
        unsetenv("PERPENDICULAR_FIXTURE_LIST_ERROR")
        await model.refresh()
        precondition(model.connectionError == nil && model.canControl)
        print("PASS: contract/readiness decoding, request serialization, errors, stale-state control lockout/recovery, independent host failure")
    }
}
