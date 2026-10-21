import AppKit
import Darwin

private struct Configuration {
    let helper: URL
    let username: String
    let port: Int
    let width: Int
    let height: Int
    let scale: Int
    let pin: String

    init(arguments: [String]) throws {
        let names: Set<String> = ["--helper", "--username", "--port", "--width", "--height", "--scale", "--pin-sha256"]
        var values: [String: String] = [:]
        guard arguments.count == names.count * 2 else { throw InvalidConfiguration() }
        for offset in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[offset]
            guard names.contains(key), values[key] == nil else { throw InvalidConfiguration() }
            values[key] = arguments[offset + 1]
        }
        guard let path = values["--helper"], path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path),
              let user = values["--username"], !user.isEmpty,
              let port = Int(values["--port"] ?? ""), (1...65535).contains(port),
              let width = Int(values["--width"] ?? ""), (200...8192).contains(width), width.isMultiple(of: 2),
              let height = Int(values["--height"] ?? ""), (200...8192).contains(height),
              let scale = Int(values["--scale"] ?? ""), (100...500).contains(scale),
              let pin = values["--pin-sha256"], pin.utf8.count == 64,
              pin.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw InvalidConfiguration() }
        helper = URL(fileURLWithPath: path)
        username = user
        self.port = port
        self.width = width
        self.height = height
        self.scale = scale
        self.pin = pin
    }

    struct InvalidConfiguration: Error {}
}

@MainActor
private final class ConnectController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let configuration: Configuration
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "Inserisci la password dell’account Windows, non il PIN.")
    private let connect = NSButton(title: "Connetti", target: nil, action: nil)
    private let cancel = NSButton(title: "Annulla", target: nil, action: nil)
    private var window: NSWindow!
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = ""
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    private var quitWhenStopped = false
    private var pendingTerminationReply = false
    private var lastDetail: String?
    private var failureDetail: String?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connetti a Windows"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()

        let title = NSTextField(labelWithString: "Prova del display Windows")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let accountLabel = NSTextField(labelWithString: "Account Windows")
        let passwordLabel = NSTextField(labelWithString: "Password")
        username.stringValue = configuration.username
        username.placeholderString = "Nome account Windows"
        password.placeholderString = "Password dell’account Windows"
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        status.setContentHuggingPriority(.defaultLow, for: .vertical)
        connect.target = self
        connect.action = #selector(startConnection)
        connect.keyEquivalent = "\r"
        cancel.target = self
        cancel.action = #selector(cancelConnection)
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, connect])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        let stack = NSStackView(views: [title, accountLabel, username, passwordLabel, password, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            username.widthAnchor.constraint(equalTo: stack.widthAnchor),
            password.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(password)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startConnection() {
        guard process == nil else { return }
        let account = username.stringValue
        guard validRecord(account, maximumBytes: 511),
              validRecord(password.stringValue, maximumBytes: 4095) else {
            password.stringValue = ""
            status.stringValue = "Inserisci account e password validi."
            return
        }

        var records = Data(account.utf8)
        records.append(10)
        records.append(contentsOf: password.stringValue.utf8)
        records.append(10)
        records.append(contentsOf: configuration.pin.utf8)
        records.append(10)
        password.stringValue = ""
        defer { records.resetBytes(in: records.startIndex..<records.endIndex) }

        let child = Process()
        let childInput = Pipe()
        let childOutput = Pipe()
        let token = UUID()
        generation = token
        outputBuffer = ""
        lastDetail = nil
        failureDetail = nil
        child.executableURL = configuration.helper
        child.arguments = [configuration.port, configuration.width, configuration.height, configuration.scale].map(String.init)
        // Explicit allowlist: no inherited proxy, WLOG, DYLD or credential variables.
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        child.standardInput = childInput
        child.standardOutput = childOutput
        child.standardError = childOutput
        childOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.consume(data, token: token) }
        }
        child.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in self?.didFinish(code: code, token: token) }
        }
        process = child
        input = childInput
        output = childOutput
        connect.isEnabled = false
        username.isEnabled = false
        password.isEnabled = false
        status.stringValue = "Connessione a Windows…"
        do {
            try child.run()
            try childInput.fileHandleForWriting.write(contentsOf: records)
            try childInput.fileHandleForWriting.close()
            input = nil
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(64)) } catch { return }
                guard let self, self.process === child, child.isRunning else { return }
                self.status.stringValue = "La prova è terminata. Disconnessione…"
                self.stopHelper()
            }
        } catch {
            try? childInput.fileHandleForWriting.close()
            if child.isRunning {
                status.stringValue = "Impossibile avviare la prova. Disconnessione…"
                stopHelper()
            } else {
                didFinish(code: 1, token: token)
            }
        }
    }

    private func validRecord(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes &&
        !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
    }

    private func consume(_ data: Data, token: UUID) {
        guard token == generation, !data.isEmpty else { return }
        outputBuffer += String(decoding: data, as: UTF8.self)
        if outputBuffer.utf8.count > 8192 { outputBuffer = ""; return }
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            showState(line)
        }
    }

    private func showState(_ line: String) {
        // Never display arbitrary child output, certificate contents or credentials.
        let state = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let observable:Set<String>=["state=connecting-loopback-nla","state=certificate-pin-verified",
            "state=certificate-pin-rejected","state=connected-nla-verified","state=display-channel-connected",
            "state=display-caps","state=layout-sent","state=server-resize","state=connection-failed",
            "state=credential-retry-rejected","state=request-exceeds-server-caps","state=layout-send-failed",
            "state=probe-incomplete-no-layout","state=disconnected"]
        if observable.contains(state) {try? FileHandle.standardError.write(contentsOf:Data((state+"\n").utf8))}
        switch state {
        case "state=connecting-loopback-nla": status.stringValue = "Connessione a Windows…"
        case "state=certificate-pin-verified": status.stringValue = "Identità di Windows verificata."
        case "state=certificate-pin-rejected":
            failureDetail = "Identità di Windows diversa da quella attesa. Connessione rifiutata."
            status.stringValue = failureDetail!
        case "state=connected-nla-verified": status.stringValue = "Connesso a Windows. La prova dura circa un minuto."
        case "state=display-channel-connected", "state=display-caps": status.stringValue = "Windows ha attivato il controllo del display."
        case "state=layout-sent":
            let detail = "Richiesta inviata: \(configuration.width) × \(configuration.height), scala \(configuration.scale)%."
            lastDetail = detail
            status.stringValue = detail
        case "state=server-resize":
            // Accept only numeric geometry fields from this known event.
            let fields = line.split(separator: " ").dropFirst()
            let values = fields.compactMap { field -> Int? in
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, pair[0] == "width" || pair[0] == "height" else { return nil }
                return Int(pair[1])
            }
            if values.count == 2, values.allSatisfy({ (200...8192).contains($0) }) {
                let detail = "Dimensione ricevuta da Windows: \(values[0]) × \(values[1])."
                lastDetail = detail
                status.stringValue = detail
            }
        case "state=credential-retry-rejected", "state=credential-input-rejected":
            failureDetail = "Windows non ha accettato le credenziali. Usa la password, non il PIN."
            status.stringValue = failureDetail!
        case "state=connection-failed":
            let code=line.split(separator:" ").first(where:{$0.hasPrefix("code=0x")}).map{String($0.dropFirst(5))}
            if let code,code.count == 10,UInt32(code.dropFirst(2),radix:16) != nil {
                try? FileHandle.standardError.write(contentsOf:Data(("rdp-error="+code+"\n").utf8))
                status.stringValue=failureDetail ?? "Connessione non riuscita (\(code))."
            }else {status.stringValue=failureDetail ?? "Connessione non riuscita."}
        case "state=request-exceeds-server-caps", "state=layout-send-failed",
             "state=probe-incomplete-no-layout", "state=server-redirection-rejected":
            status.stringValue = failureDetail ?? "La prova non è stata completata."
        case "state=disconnected": break
        default: break
        }
    }

    @objc private func cancelConnection() {
        password.stringValue = ""
        if process == nil { window.close() }
        else { status.stringValue = "Disconnessione…"; stopHelper() }
    }

    private func stopHelper() {
        timeout?.cancel()
        timeout = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        guard let owned = process, owned.isRunning else { return }
        // Signals target only the Process instance launched by this controller.
        owned.terminate()
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, self.process === owned, owned.isRunning else { return }
            kill(owned.processIdentifier, SIGKILL)
        }
    }

    private func didFinish(code: Int32, token: UUID) {
        guard token == generation, process != nil else { return }
        timeout?.cancel()
        timeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        process = nil
        password.stringValue = ""
        connect.isEnabled = true
        username.isEnabled = true
        password.isEnabled = true
        if code == 0 {
            status.stringValue = "Prova terminata. " + (lastDetail ?? "La sessione è stata chiusa.")
        } else if status.stringValue == "Disconnessione…" || status.stringValue == "La prova è terminata. Disconnessione…" {
            status.stringValue = "Disconnesso."
        } else if status.stringValue == "Connessione a Windows…" {
            status.stringValue = "Connessione non riuscita. Verifica la password dell’account Windows."
        }
        if pendingTerminationReply { NSApp.reply(toApplicationShouldTerminate: true) }
        else if quitWhenStopped { NSApp.terminate(self) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        password.stringValue = ""
        guard process != nil else { return true }
        quitWhenStopped = true
        stopHelper()
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        password.stringValue = ""
        guard process != nil else { return .terminateNow }
        pendingTerminationReply = true
        stopHelper()
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
@MainActor
private struct ConnectDisplay {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        do {
            let controller = ConnectController(configuration: try Configuration(arguments: Array(CommandLine.arguments.dropFirst())))
            app.delegate = controller
            withExtendedLifetime(controller) { app.run() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossibile preparare la connessione"
            alert.informativeText = "I parametri della prova sono incompleti o non validi."
            alert.runModal()
        }
    }
}
