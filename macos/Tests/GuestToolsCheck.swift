import Foundation

@MainActor
private final class RecordingClipboard: GuestClipboard {
    var value: String?
    var reads = 0
    var writes = 0
    func readText() -> String? { reads += 1; return value }
    func replaceText(_ text: String) throws { writes += 1; value = text }
}

/// Exercises the real CLI boundary with private static fixtures, never the user's
/// clipboard or VM. Readiness polling must not access a clipboard in either OS.
@main
@MainActor
struct GuestToolsCheck {
    static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("perpendicular-guest-check-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let fixture = root.appendingPathComponent("engine-fixture")
        let mode = root.appendingPathComponent("mode")
        let calls = root.appendingPathComponent("calls")
        let program = #"""
        #!/usr/bin/python3
        import json,pathlib,sys
        root=pathlib.Path(__file__).parent
        mode=(root/'mode').read_text() if (root/'mode').exists() else 'online'
        command=sys.argv[1]
        with (root/'calls').open('a') as f: f.write(command+'\n')
        def output(value): print(json.dumps(value,ensure_ascii=False))
        def error(message): output({'error':{'code':'guest_agent_unavailable','message':message}});sys.exit(1)
        if command=='guest-status':
          if mode=='offline': output({'status':{'connected':False,'code':'guest_agent_unavailable','reason':'Guest Tools are not running.','capabilities':{'clipboard':False,'file_write':False}}})
          else: output({'status':{'connected':True,'protocol':1,'agent_version':'0.1.0','capabilities':{'clipboard':mode!='no-capabilities','file_write':mode!='no-capabilities','max_clipboard_bytes':262144,'max_file_bytes':1048576},'secure_boot':True,'tpm':{'present':True,'ready':'unknown'}}})
        elif command=='guest-clipboard-read':
          if mode=='read-error': error('Windows clipboard is unavailable.')
          output({'text':'🌍'*65537 if mode=='oversize-read' else 'Windows sample 🌍'})
        elif command=='guest-clipboard-write':
          payload=pathlib.Path(sys.argv[sys.argv.index('--text-file')+1])
          if payload.stat().st_mode&0o777!=0o600: error('Clipboard payload is not private.')
          if payload.parent.stat().st_mode&0o777!=0o700: error('Clipboard folder is not private.')
          with (root/'payload-paths').open('a') as f: f.write(str(payload)+'\n')
          text=payload.read_text()
          if text!='Mac sample λ': error('Unexpected fixture clipboard input.')
          output({'written':mode!='write-unconfirmed'})
        elif command=='guest-file-push':
          source=pathlib.Path(sys.argv[sys.argv.index('--source')+1]);name=sys.argv[sys.argv.index('--name')+1]
          output({'name':name,'bytes_written':0 if mode=='partial-file' else source.stat().st_size,'path':str(pathlib.PureWindowsPath('C:/Users/Guest/Downloads')/name)})
        else: error('Unexpected fixture command.')
        """#
        try program.write(to: fixture, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        setenv("PERPENDICULAR_ENGINE", fixture.path, 1)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vm = try decoder.decode(VirtualMachine.self, from: Data(#"{"id":"guest-check","name":"Test","state":"running","cpus":4,"memory_mib":8192,"disk_gib":64,"directory":"/tmp/vm","disk_path":"/tmp/vm/disk","created_at":"2026-10-15T10:00:00Z","backend":"qemu-hvf","qmp_socket":"/tmp/qmp","vnc_socket":"/tmp/vnc"}"#.utf8))
        let clipboard = RecordingClipboard()
        let tools = GuestToolsController(engine: EngineClient(), clipboard: clipboard)

        try "offline".write(to: mode, atomically: true, encoding: .utf8)
        await tools.checkStatus(for: vm)
        await tools.copyFromWindows(vm)
        precondition(clipboard.reads == 0 && clipboard.writes == 0)
        precondition(tools.statuses[vm.id]?.connected == false && tools.feedback[vm.id]?.isError == true)

        try "online".write(to: mode, atomically: true, encoding: .utf8)
        await tools.checkStatus(for: vm)
        precondition(clipboard.reads == 0 && clipboard.writes == 0, "Readiness touched clipboard contents")
        precondition(tools.statuses[vm.id]?.secureBoot == .known(true) && tools.statuses[vm.id]?.tpm?.ready == .unknown)
        await tools.copyFromWindows(vm)
        precondition(clipboard.writes == 1 && clipboard.reads == 0 && clipboard.value == "Windows sample 🌍")

        try "read-error".write(to: mode, atomically: true, encoding: .utf8)
        await tools.copyFromWindows(vm)
        precondition(clipboard.writes == 1 && clipboard.value == "Windows sample 🌍" && tools.feedback[vm.id]?.isError == true)
        try "oversize-read".write(to: mode, atomically: true, encoding: .utf8)
        await tools.copyFromWindows(vm)
        precondition(clipboard.writes == 1, "Oversized guest text overwrote the Mac clipboard")

        try "online".write(to: mode, atomically: true, encoding: .utf8)
        clipboard.value = "Mac sample λ"
        await tools.sendClipboardToWindows(vm)
        precondition(clipboard.reads == 1 && clipboard.writes == 1 && tools.feedback[vm.id]?.isError == false)
        try "write-unconfirmed".write(to: mode, atomically: true, encoding: .utf8)
        await tools.sendClipboardToWindows(vm)
        precondition(tools.feedback[vm.id]?.isError == true)
        let beforeOversize = try String(contentsOf: calls, encoding: .utf8)
        clipboard.value = String(repeating: "🌍", count: 65537)
        await tools.sendClipboardToWindows(vm)
        let afterOversize = try String(contentsOf: calls, encoding: .utf8)
        precondition(afterOversize == beforeOversize, "Oversized text was sent to the engine")

        let source = root.appendingPathComponent("source.txt")
        try Data("small test file".utf8).write(to: source)
        try "online".write(to: mode, atomically: true, encoding: .utf8)
        let sent = await tools.sendFile(source, name: "guest-note.txt", to: vm)
        precondition(sent && tools.feedback[vm.id]?.isError == false)
        try "partial-file".write(to: mode, atomically: true, encoding: .utf8)
        let partial = await tools.sendFile(source, name: "guest-note.txt", to: vm)
        precondition(!partial && tools.feedback[vm.id]?.isError == true)
        try Data(count: 1048577).write(to: source)
        let beforeLargeFile = try String(contentsOf: calls, encoding: .utf8)
        let large = await tools.sendFile(source, name: "too-large.dat", to: vm)
        precondition(!large)
        let afterLargeFile = try String(contentsOf: calls, encoding: .utf8)
        precondition(afterLargeFile == beforeLargeFile, "Oversized file reached the engine")
        let payloadPaths = try String(contentsOf: root.appendingPathComponent("payload-paths"), encoding: .utf8).split(separator: "\n")
        precondition(payloadPaths.count == 2)
        for path in payloadPaths { precondition(!files.fileExists(atPath: String(path)), "Clipboard payload survived a completed or failed transfer") }
        try "no-capabilities".write(to: mode, atomically: true, encoding: .utf8)
        await tools.checkStatus(for: vm)
        let beforeUnsupported = try String(contentsOf: calls, encoding: .utf8)
        let readsBeforeUnsupported = clipboard.reads
        await tools.sendClipboardToWindows(vm)
        await tools.copyFromWindows(vm)
        let unsupportedFile = await tools.sendFile(source, name: "unsupported.dat", to: vm)
        let afterUnsupported = try String(contentsOf: calls, encoding: .utf8)
        precondition(!unsupportedFile && clipboard.reads == readsBeforeUnsupported && clipboard.writes == 1 && beforeUnsupported == afterUnsupported)
        precondition(!tools.isBusy)
        print("PASS: readiness privacy, explicit clipboard writes, failed copy preservation, UTF-8 limits, private payload cleanup, capability gates, file size and confirmations")
    }
}
