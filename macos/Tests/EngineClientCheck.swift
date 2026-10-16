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
        printf '%s\n' "$1" >>"$(dirname "$0")/calls"
        case "$1" in
          list)
            if [ "${PERPENDICULAR_FIXTURE_LIST_ERROR:-0}" = 1 ]; then
              printf '%s\n' '{"error":{"code":"list_failed","message":"Library connection lost."}}'; exit 1
            fi
            printf '%s\n' '{"vms":[{"id":"vm-123","name":"Windows 11","state":"'"${PERPENDICULAR_FIXTURE_STATE:-paused}"'","cpus":4,"memory_mib":8192,"disk_gib":80,"iso_path":null,"directory":"/tmp/vm","disk_path":"/tmp/vm/disk.qcow2","created_at":"2026-10-15T10:00:00Z","backend":"qemu-hvf","qmp_socket":"/tmp/qmp","vnc_socket":"/tmp/vnc","last_error":null'"${PERPENDICULAR_FIXTURE_ADAPTER_JSON:-}"'}]}' ;;
          system-info)
            if [ "${PERPENDICULAR_FIXTURE_SYSTEM_ERROR:-0}" = 1 ]; then
              printf '%s\n' '{"error":{"code":"system_info_failed","message":"System information failed."}}'; exit 1
            fi
            printf '%s\n' '{"architecture":"aarch64","memory_bytes":25769803776,"hypervisor_available":true,"qemu_path":null,"qemu_img_path":null,"firmware_code_path":null,"firmware_vars_path":null,"swtpm_path":null,"data_dir":"/tmp/VMs","firmware_secure_boot_capable":true,"secure_boot_verified":false,"windows_readiness":{"graphics":"Not accelerated","network":"Guest driver required","secure_boot":"guest_verification_required","tpm_available":false}}' ;;
          update)
            printf '%s\n' "$@" >"$(dirname "$0")/last-update"
            if [ "${PERPENDICULAR_FIXTURE_UPDATE_ERROR:-0}" = 1 ]; then
              printf '%s\n' '{"error":{"code":"update_failed","message":"The selected display could not be saved."}}'; exit 1
            fi
            printf '%s\n' '{}' ;;
          error) printf '%s\n' '{"error":{"code":"invalid_state","message":"Shut down the virtual machine first."}}'; exit 1 ;;
          transport-error) printf '%s\n' '{"error":{"code":"guest_agent_timeout","message":"Fixture exchange expired."}}'; exit 1 ;;
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
        precondition(vm.displayAdapter == .ramfb, "Historical JSON must keep the standard display")
        precondition(vm.nativeDisplay == nil, "Historical JSON has no native stream")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var vmJSON = try JSONSerialization.jsonObject(with: encoder.encode(vm)) as! [String: Any]
        for adapter in DisplayAdapter.allCases {
            vmJSON["display_adapter"] = adapter.rawValue
            let decoded = try decoder.decode(VirtualMachine.self, from: JSONSerialization.data(withJSONObject: vmJSON))
            precondition(decoded.displayAdapter == adapter)
            let encoded = try JSONSerialization.jsonObject(with: encoder.encode(decoded)) as! [String: Any]
            precondition(encoded["display_adapter"] as? String == adapter.rawValue)
        }
        let endpointJSON = Data("""
        {"socket_path":"/tmp/vm/native-display.sock","server_pid":123,"expected_uid":501,
         "session_hi":17375808098319191535,"session_lo":1311768467463790321,"epoch":1}
        """.utf8)
        let endpoint = try decoder.decode(NativeDisplayEndpoint.self, from: endpointJSON)
        precondition(endpoint.serverPID == 123 && endpoint.expectedUID == 501)
        precondition(endpoint.sessionHi == 0xf123456789abcdef && endpoint.sessionLo == 0x123456789abcdef1,
                     "Launch identity must retain all64bits")
        vmJSON["native_display"] = try JSONSerialization.jsonObject(with: endpointJSON)
        let nativeVM = try decoder.decode(VirtualMachine.self, from: JSONSerialization.data(withJSONObject: vmJSON))
        precondition(nativeVM.nativeDisplay == endpoint)
        vmJSON.removeValue(forKey: "native_display")
        for invalid: Any in ["unknown-display", 1, NSNull()] {
            vmJSON["display_adapter"] = invalid
            do {
                _ = try decoder.decode(VirtualMachine.self, from: JSONSerialization.data(withJSONObject: vmJSON))
                fatalError("Invalid display adapter was silently accepted")
            } catch is DecodingError {}
        }
        let host: HostInfo = try await client.execute(["system-info"])
        precondition(host.memoryGib == 24 && host.hypervisorAvailable && !host.readyToStart && host.qemuPath == nil)
        precondition(host.firmwareSecureBootCapable == true && host.secureBootVerified == false)
        precondition(host.windowsReadiness?.secureBoot == "guest_verification_required")
        do {
            let _: CommandResult = try await client.execute(["error"])
            fatalError("Nonzero engine status was accepted")
        } catch {
            precondition(error.localizedDescription == "Shut down the virtual machine first.")
            precondition((error as? EngineFailure)?.code == "invalid_state")
        }
        do {
            let _: CommandResult = try await client.execute(["transport-error"])
            fatalError("Guest transport failure was accepted")
        } catch {
            precondition((error as? EngineFailure)?.code == "guest_agent_timeout")
            precondition(error.localizedDescription == "Fixture exchange expired.")
        }
        do {
            let _: VMListResult = try await client.execute(["malformed"])
            fatalError("Invalid JSON was accepted")
        } catch {
            precondition(error.localizedDescription.contains("unreadable response"))
            precondition((error as? EngineFailure)?.code == nil)
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

        func update(_ adapter: DisplayAdapter, vmID: String = "vm-123") async throws {
            try await model.updateConfiguration(vmID: vmID, name: "  Windows Updated  ", cpus: 6, memory: 12288,
                keyboardLayout: "it", audioOutput: true, displayAdapter: adapter, iso: nil, driverISO: nil)
        }
        func calls() throws -> String { try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8) }
        func lastUpdate() throws -> [String] {
            try String(contentsOf: root.appendingPathComponent("last-update"), encoding: .utf8).split(separator: "\n").map(String.init)
        }
        for state in ["running", "paused", "starting", "stopping", "crashed", "unknown"] {
            setenv("PERPENDICULAR_FIXTURE_STATE", state, 1)
            await model.refresh()
            precondition(!model.canConfigure(vmID: vm.id))
            let before = try calls()
            do { try await update(.virtioRAMFB); fatalError("Non-stopped VM configuration was accepted") }
            catch { precondition(error.localizedDescription.contains("Shut down")) }
            let after = try calls()
            precondition(before == after, "A stale settings sheet reached the engine")
        }
        setenv("PERPENDICULAR_FIXTURE_STATE", "stopped", 1)
        await model.refresh()
        precondition(model.canConfigure(vmID: vm.id) && !model.canConfigure(vmID: "missing-vm"))
        let beforeMissing = try calls()
        do { try await update(.virtioRAMFB, vmID: "missing-vm"); fatalError("Missing VM configuration was accepted") }
        catch { precondition(error.localizedDescription.contains("Shut down")) }
        let afterMissing = try calls()
        precondition(beforeMissing == afterMissing)
        let expected = ["update", vm.id, "--name", "Windows Updated", "--cpus", "6", "--memory-mib", "12288",
                        "--keyboard-layout", "it", "--audio-output", "true"]
        try await update(.ramfb)
        let unchanged = try lastUpdate()
        precondition(unchanged == expected, "Saving other settings must not request an implicit display change")
        try await update(.virtioRAMFB)
        let adaptive = try lastUpdate()
        precondition(adaptive == expected + ["--display-adapter", "virtio-ramfb"])
        setenv("PERPENDICULAR_FIXTURE_ADAPTER_JSON", #","display_adapter":"virtio-ramfb""#, 1)
        await model.refresh()
        precondition(model.selectedVM?.displayAdapter == .virtioRAMFB)
        try await update(.ramfb)
        let standard = try lastUpdate()
        precondition(standard == expected + ["--display-adapter", "ramfb"])
        setenv("PERPENDICULAR_FIXTURE_LIST_ERROR", "1", 1)
        await model.refresh()
        precondition(!model.canConfigure(vmID: vm.id))
        let beforeDisconnected = try calls()
        do { try await update(.ramfb); fatalError("Disconnected library allowed a configuration update") }
        catch { precondition(error.localizedDescription.contains("Shut down")) }
        let afterDisconnected = try calls()
        precondition(beforeDisconnected == afterDisconnected)
        unsetenv("PERPENDICULAR_FIXTURE_LIST_ERROR")
        await model.refresh()
        setenv("PERPENDICULAR_FIXTURE_UPDATE_ERROR", "1", 1)
        do { try await update(.ramfb); fatalError("Failed display update was reported as saved") }
        catch { precondition(error.localizedDescription == "The selected display could not be saved.") }
        precondition(model.canConfigure(vmID: vm.id) && !model.isBusy)
        unsetenv("PERPENDICULAR_FIXTURE_UPDATE_ERROR")
        unsetenv("PERPENDICULAR_FIXTURE_ADAPTER_JSON")
        unsetenv("PERPENDICULAR_FIXTURE_STATE")
        print("PASS: contract/readiness decoding, request serialization, errors, stale-state control lockout/recovery, independent host failure; legacy/strict display decoding, exact display update arguments in both directions, no implicit display update, stopped-only and disconnected/missing VM guards, update error recovery")
    }
}
