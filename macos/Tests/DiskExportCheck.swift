import AppKit
import Foundation

/// Tests native destination selection and the real process/JSON boundary with an
/// owned fixture. No VM process, guest agent or system clipboard is contacted.
@main
@MainActor
struct DiskExportCheck {
    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("perpendicular-export-check-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let fixture = root.appendingPathComponent("engine-fixture")
        let state = root.appendingPathComponent("state")
        let mode = root.appendingPathComponent("mode")
        let calls = root.appendingPathComponent("calls")
        let marker = root.appendingPathComponent("export-active")
        let release = root.appendingPathComponent("release")
        let program = #"""
        #!/usr/bin/python3
        import json,pathlib,sys,time
        root=pathlib.Path(__file__).parent
        state=(root/'state').read_text() if (root/'state').exists() else 'stopped'
        mode=(root/'mode').read_text() if (root/'mode').exists() else 'success'
        cmd=sys.argv[1]
        with (root/'calls').open('a') as stream: stream.write(cmd+'\n')
        def output(value): print(json.dumps(value))
        def error(code,message): output({'error':{'code':code,'message':message}});sys.exit(1)
        vm={'id':'export-vm','name':'Export Test','state':state,'cpus':4,'memory_mib':8192,'disk_gib':64,'directory':'/tmp/export-vm','disk_path':'/tmp/export-vm/disk','created_at':'2026-10-15T10:00:00Z','backend':'qemu-hvf','qmp_socket':'/tmp/qmp','vnc_socket':'/tmp/vnc'}
        if cmd=='system-info': output({'architecture':'aarch64','memory_bytes':25769803776,'hypervisor_available':True,'data_dir':str(root)})
        elif cmd=='list': output({'vms':[vm],'errors':[]})
        elif cmd=='export-disk':
          if state!='stopped': error('vm_not_stopped','Shut down this virtual machine before exporting.')
          path=pathlib.Path(sys.argv[sys.argv.index('--destination')+1]);fmt=sys.argv[sys.argv.index('--format')+1]
          if path.exists() or path.is_symlink(): error('destination_exists','The destination already exists. Choose a new file name.')
          if mode=='hold':
            (root/'export-active').touch()
            deadline=time.monotonic()+8
            while not (root/'release').exists() and time.monotonic()<deadline: time.sleep(.02)
            if not (root/'release').exists(): error('fixture_timeout','Test did not release the export.')
          if mode=='failure': error('export_failed','The destination disk has no free space.')
          payload=b'independent exported disk fixture'
          if mode!='missing-artifact':
            with path.open('xb') as stream: stream.write(payload)
          output({'export':{'vm_id':'wrong-vm' if mode=='wrong-vm' else vm['id'],'path':str(path.resolve()),'format':fmt,'virtual_size_bytes':68719476736,'size_bytes':len(payload)+(1 if mode=='wrong-size' else 0)}})
        else: error('unexpected_command','A conflicting command reached the engine.')
        """#
        try program.write(to: fixture, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        setenv("PERPENDICULAR_ENGINE", fixture.path, 1)
        let model = LibraryModel()
        await model.load()
        guard let vm = model.selectedVM else { fatalError("Fixture did not load its VM") }

        for activeState in ["running", "paused", "starting", "stopping", "crashed"] {
            try activeState.write(to: state, atomically: true, encoding: .utf8)
            await model.refresh()
            let before = try String(contentsOf: calls, encoding: .utf8)
            do {
                _ = try await model.exportDisk(vmID: vm.id, destination: root.appendingPathComponent("active.qcow2"), format: "qcow2")
                fatalError("Active VM export was accepted")
            } catch { precondition(error.localizedDescription.contains("Shut down")) }
            let after = try String(contentsOf: calls, encoding: .utf8)
            precondition(before == after, "An active VM reached the export backend")
        }
        try "stopped".write(to: state, atomically: true, encoding: .utf8)
        await model.refresh()
        try "hold".write(to: mode, atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("export.qcow2")
        let transfer = Task { try await model.exportDisk(vmID: vm.id, destination: destination, format: "qcow2") }
        let deadline = Date().addingTimeInterval(5)
        while !files.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(files.fileExists(atPath: marker.path), "No live fixture export was observed")
        precondition(model.isBusy && !model.canControl && !model.operation.isEmpty)
        let beforeBusyActions = try String(contentsOf: calls, encoding: .utf8)
        await model.refresh()
        await model.load()
        await model.checkHost()
        await model.loadSnapshots(for: vm)
        do { try await model.perform(["start", vm.id], operation: "Start"); fatalError("Start overlapped export") }
        catch { precondition(error.localizedDescription.contains("in progress")) }
        do { try await model.clone(vm, name: "Conflicting clone"); fatalError("Clone overlapped export") }
        catch { precondition(error.localizedDescription.contains("in progress")) }
        let heartbeat = Task { @MainActor in true }
        let heartbeatRan = await heartbeat.value
        precondition(heartbeatRan, "The main actor was blocked by export")
        let afterBusyActions = try String(contentsOf: calls, encoding: .utf8)
        precondition(beforeBusyActions == afterBusyActions, "A poll or mutation was enqueued during export")
        try Data().write(to: release)
        let exported = try await transfer.value
        precondition(exported.vmId == vm.id && exported.format == "qcow2" && exported.virtualSizeBytes == 68719476736)
        precondition(!model.isBusy && model.canControl && model.operation.isEmpty)

        let original = try Data(contentsOf: destination)
        do { _ = try await model.exportDisk(vmID: vm.id, destination: destination, format: "qcow2"); fatalError("Existing export was replaced") }
        catch { precondition(error.localizedDescription.contains("already exists")) }
        let preserved = try Data(contentsOf: destination)
        precondition(preserved == original)
        for invalidMode in ["failure", "missing-artifact", "wrong-vm", "wrong-size"] {
            try invalidMode.write(to: mode, atomically: true, encoding: .utf8)
            do {
                _ = try await model.exportDisk(vmID: vm.id, destination: root.appendingPathComponent("\(invalidMode).qcow2"), format: "qcow2")
                fatalError("Failed or unverified export was reported as successful")
            } catch { precondition(!model.isBusy && model.operation.isEmpty) }
        }
        try "success".write(to: mode, atomically: true, encoding: .utf8)
        let raw = try await model.exportDisk(vmID: vm.id, destination: root.appendingPathComponent("export.img"), format: "raw")
        precondition(raw.format == "raw")

        _ = NSApplication.shared
        let panel = NSSavePanel()
        let controller = DiskExportSavePanelController(panel: panel, proposedName: "Windows 11")
        precondition(panel.nameFieldStringValue == "Windows 11.qcow2" && !panel.isExtensionHidden)
        let selector = NSPopUpButton()
        selector.addItems(withTitles: DiskExportFormat.allCases.map(\.label))
        selector.selectItem(at: 1)
        controller.formatChanged(selector)
        precondition(controller.format == .raw && panel.nameFieldStringValue == "Windows 11.img")
        selector.selectItem(at: 0)
        controller.formatChanged(selector)
        precondition(controller.format == .qcow2 && panel.nameFieldStringValue == "Windows 11.qcow2")
        do { try controller.panel(panel, validate: destination); fatalError("Save panel accepted an existing file") } catch {}
        let broken = root.appendingPathComponent("broken.qcow2")
        try files.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing"))
        precondition(DiskExportSavePanelController.destinationExists(broken))
        do { try controller.panel(panel, validate: broken); fatalError("Save panel accepted a dangling symbolic link") } catch {}
        try controller.panel(panel, validate: root.appendingPathComponent("new.qcow2"))
        print("PASS: stopped-VM export contract, async responsiveness, global busy lockout, no conflicting polls/mutations, error recovery, artifact validation, no overwrite, native format/extension and dangling-link checks")
    }
}
