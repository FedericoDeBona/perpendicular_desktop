import AppKit
import CryptoKit
import Darwin
import Security
import SwiftUI

@MainActor
final class NetworkSettings:ObservableObject {
    @Published var addresses:[String]=[]
    @Published private(set) var savedAddresses:[String]=[]
    @Published private(set) var installed=false
    @Published private(set) var installationPending=false
    @Published private(set) var enabled=false
    @Published private(set) var busy=false
    @Published private(set) var connected=false
    @Published private(set) var tunnelActive=false
    @Published private(set) var title="Non installato"
    @Published private(set) var detail=""
    @Published private(set) var error:String?
    private var machine:VirtualMachineController?
    private var bridge:GuestBridge?
    private var guestBusy:()->Bool = {false}
    private var operation:Task<Void,Never>?
    private var observation:Task<Void,Never>?
    private var checking=false
    private var runtimeStamp=""
    private var guestVerified=false
    private var recovery:Task<Void,Never>?
    private var root:URL {machine!.directory.appendingPathComponent("HostVPN")}
    private var preferences:URL {machine!.directory.appendingPathComponent("network-settings.json")}
    private var payload:URL {Bundle.main.resourceURL!.appendingPathComponent("Network")}
    private let windowsRoot=#"C:\ProgramData\Perpendicular\HostVPN"#
    var dirty:Bool {addresses != savedAddresses}

    func configure(machine:VirtualMachineController,bridge:GuestBridge,guestBusy:@escaping ()->Bool){
        guard self.machine !== machine else{return}
        self.machine=machine;self.bridge=bridge;self.guestBusy=guestBusy
        do {
            var prefs:[String:Any]=[:]
            if FileManager.default.fileExists(atPath:preferences.path){prefs=try Self.json(preferences)}
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("connection.json").path){
                let metadata=try Self.json(root.appendingPathComponent("connection.json"))
                guard metadata["machine_uuid"] as? String == machine.configuration.id else{throw Self.failure("Il collegamento di rete appartiene a un'altra macchina Windows.")}
                let cidrs=metadata["targets"] as? [String] ?? []
                addresses=try Self.normalized(cidrs.map{String($0.split(separator:"/")[0])})
                installed=true
            }else{addresses=try Self.normalized(prefs["addresses"] as? [String] ?? [])}
            savedAddresses=addresses
            installationPending=FileManager.default.fileExists(atPath:root.appendingPathComponent("pending-install.json").path)
            enabled=prefs["enabled"] as? Bool ?? FileManager.default.fileExists(atPath:root.appendingPathComponent("tun.sock").path)
            title=installed ? "In attesa di Windows":"Non installato"
            if installed {try verifyRuntime()}
        }catch{self.error=error.localizedDescription;title="Configurazione da verificare"}
    }
    func connectionChanged(_ ready:Bool){
        connected=ready;guestVerified=false;recovery?.cancel();recovery=nil
        if !ready {
            operation?.cancel();title=installed ? "In attesa di Windows":"Non installato"
            detail=enabled ? "L'inoltro riprenderà quando Windows sarà collegato.":""
            return
        }
        recovery=Task{@MainActor [weak self] in
            guard let self else{return}
            // Folder setup shares the guest execution slot. Wait for its real
            // completion; do not race it or start another installer.
            for _ in 0..<60 {
                guard !Task.isCancelled,self.connected else{return}
                if !self.guestBusy(),!self.busy {break}
                try? await Task.sleep(for:.seconds(2))
            }
            guard !Task.isCancelled,self.connected,!self.guestBusy(),!self.busy else{return}
            if self.installationPending {self.title="Installazione da completare"}
            else if self.enabled,self.installed {self.activate()}
            else {self.refresh()}
        }
    }
    func observe(){
        observation?.cancel()
        refresh()
        observation=Task{@MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(5))
                guard !Task.isCancelled,let self else{return}
                if self.connected,!self.busy,!self.guestBusy(){self.refresh()}
            }
        }
    }
    func stopObserving(){observation?.cancel();observation=nil}
    func stop(){stopObserving();recovery?.cancel();operation?.cancel()}
    func add(_ input:String)throws {
        let next=try Self.normalized(addresses+[input]);guard next.count<=64 else{throw Self.failure("Puoi inoltrare fino a 64 indirizzi.")}
        addresses=next;error=nil
    }
    func remove(_ address:String){addresses.removeAll{$0==address};error=nil}
    static func normalized(_ values:[String])throws->[String] {
        var result=Set<String>()
        for value in values {
            let text=value.trimmingCharacters(in:.whitespacesAndNewlines)
            let fields=text.split(separator:".",omittingEmptySubsequences:false)
            guard fields.count==4 else{throw failure("Inserisci un singolo indirizzo IPv4 privato, per esempio 192.168.10.111.")}
            let bytes=fields.compactMap{UInt8($0)}
            guard bytes.count==4,zip(fields,bytes).allSatisfy({String($0.1)==String($0.0)}),
                  bytes[0]==10 || (bytes[0]==172 && (16...31).contains(bytes[1])) || (bytes[0]==192 && bytes[1]==168) else{
                throw failure("Usa un indirizzo privato completo: 10.x.x.x, 172.16–31.x.x o 192.168.x.x.")
            }
            result.insert(bytes.map(String.init).joined(separator:"."))
        }
        guard result.count<=64 else{throw failure("Puoi inoltrare fino a 64 indirizzi.")}
        return result.sorted()
    }
    func refresh(){
        guard !busy,!checking,!guestBusy(),!installationPending else{return}
        if !connected {title=installed ? "In attesa di Windows":"Non installato";return}
        checking=true
        Task{@MainActor [weak self] in
            guard let self else{return};defer{self.checking=false}
            do{try await self.probe()}
            catch{if !Task.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func setEnabled(_ value:Bool){if value{activate()}else{deactivate()}}
    func activate(){
        guard installed,connected,!busy,!installationPending else{return}
        perform("Attivazione inoltro…"){
            guard !self.savedAddresses.isEmpty else{throw Self.failure("Aggiungi e salva almeno un indirizzo prima di attivare l'inoltro.")}
            try self.verifyRuntime()
            try await self.forwarding(true)
            _ = try await self.ps(#"Start-ScheduledTask -TaskName 'PerpendicularHostVPN'"#)
            if try await !self.tunnel() {
                _ = try await Self.run(self.root.appendingPathComponent("authorize"),[self.root.appendingPathComponent("supervisor").path,self.root.path])
                for _ in 0..<30 {
                    if try await self.tunnel(){break}
                    try await Task.sleep(for:.milliseconds(200))
                }
                guard try await self.tunnel() else{throw Self.failure("Il tunnel Mac non si è avviato. Riprova l'attivazione.")}
            }
            self.enabled=true;try self.savePreferences();try await self.probe()
        }
    }
    func deactivate(){
        guard installed,!installationPending,!busy else{return}
        perform("Disattivazione inoltro…"){
            self.enabled=false;try self.savePreferences()
            if try await self.tunnel(){_ = try await self.tunnel(command:"stop")}
            for _ in 0..<50 {
                if try await !self.tunnel(){break}
                try await Task.sleep(for:.milliseconds(200))
            }
            guard try await !self.tunnel() else{throw Self.failure("Il tunnel Mac non ha ancora terminato l'arresto.")}
            if self.connected {_ = try await self.ps(#"Stop-ScheduledTask -TaskName 'PerpendicularHostVPN'"#);try await self.forwarding(false)}
            self.tunnelActive=false;self.title="Disattivato";self.detail="Gli indirizzi e la VPN Windows restano configurati."
        }
    }
    func applyAddresses(){
        guard !busy,!installationPending else{return}
        perform("Salvataggio indirizzi…"){
            let next=try Self.normalized(self.addresses)
            guard !next.isEmpty else{throw Self.failure("Mantieni almeno un indirizzo; per fermare il collegamento disattiva l'inoltro.")}
            if !self.installed {self.savedAddresses=next;try self.savePreferences();self.title="Non installato";return}
            guard self.connected else{throw Self.failure("Collega Windows per applicare gli indirizzi su entrambi i sistemi.")}
            try self.verifyRuntime()
            let cidrs=next.map{$0+"/32"}
            let encoded=try JSONSerialization.data(withJSONObject:cidrs).base64EncodedString()
            let script=#"""
            $d='C:\ProgramData\Perpendicular\HostVPN';$c=Get-Content "$d\server.json" -Raw|ConvertFrom-Json;
            $r=@($c.route.rules|Where-Object outbound -eq 'vpn');if($r.Count -ne 1){throw 'Unexpected relay rules'};
            $r[0].ip_cidr=[string[]](ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\#(encoded)'))));
            [IO.File]::WriteAllText("$d\server.pending.json",($c|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));
            & "$d\sing-box.exe" check -c "$d\server.pending.json";if($LASTEXITCODE -ne 0){throw 'Relay configuration rejected'};
            Copy-Item "$d\server.json" "$d\server.previous.json" -Force;
            Stop-ScheduledTask PerpendicularHostVPN;
            for($i=0;$i -lt 30 -and (Get-ScheduledTask PerpendicularHostVPN).State -eq 'Running';$i++){Start-Sleep -Milliseconds 100};
            if((Get-ScheduledTask PerpendicularHostVPN).State -eq 'Running'){throw 'Relay has not stopped'};
            Move-Item "$d\server.pending.json" "$d\server.json" -Force;\#(self.enabled ? "Start-ScheduledTask PerpendicularHostVPN":"")
            """#
            var client=try Self.json(self.root.appendingPathComponent("client-tun.json"))
            var inbound=client["inbounds"] as? [[String:Any]] ?? []
            guard inbound.count==1 else{throw Self.failure("Configurazione del tunnel non riconosciuta.")}
            inbound[0]["route_address"]=cidrs;client["inbounds"]=inbound
            let pending=self.root.appendingPathComponent("client-tun.pending.json")
            try Self.write(client,to:pending)
            _ = try await Self.run(self.root.appendingPathComponent("sing-box"),["check","-c",pending.path])
            let path=self.root.appendingPathComponent("client-tun.json")
            let metadataPath=self.root.appendingPathComponent("connection.json")
            let previous=try Self.json(path),oldMetadata=try Self.json(metadataPath)
            // Keep a recovery copy before changing either side.
            try Self.write(previous,to:self.root.appendingPathComponent("client-tun.previous.json"))
            _ = try await self.ps(script)
            do {
                try Self.write(client,to:path)
                var metadata=oldMetadata;metadata["targets"]=cidrs
                try Self.write(metadata,to:metadataPath)
                if try await self.tunnel(){_ = try await self.tunnel(command:"reload")}
            }catch {
                let original=error
                do {
                    try Self.write(previous,to:path);try Self.write(oldMetadata,to:metadataPath)
                    _ = try await self.ps(#"$d='C:\ProgramData\Perpendicular\HostVPN';Stop-ScheduledTask PerpendicularHostVPN;Start-Sleep -Milliseconds 500;Copy-Item "$d\server.previous.json" "$d\server.json" -Force;\#(self.enabled ? "Start-ScheduledTask PerpendicularHostVPN":"")"#)
                    if try await self.tunnel(){_ = try await self.tunnel(command:"reload")}
                }catch{throw Self.failure("Aggiornamento incompleto. Usa Installa o ripara per riallineare gli indirizzi sui due sistemi.")}
                throw original
            }
            self.savedAddresses=next;try self.savePreferences();try await self.probe()
        }
    }
    func install(){
        guard connected,!busy else{return}
        perform("Installazione collegamento…"){
            if self.installationPending {try await self.finishInstallation();return}
            let selected=try Self.normalized(self.addresses)
            let blocks=try await self.qmp("query-block") as? [[String:Any]] ?? []
            guard let cd=blocks.first(where:{$0["device"] as? String == "bootstrap"}),cd["inserted"] == nil else{throw Self.failure("Espelli il CD collegato a Windows prima di installare la rete.")}
            guard !selected.isEmpty else{throw Self.failure("Aggiungi almeno un indirizzo da inoltrare.")}
            try self.installLocal(selected)
            let request=UUID().uuidString.lowercased()
            let setup=self.root.appendingPathComponent("Setup-"+request)
            try FileManager.default.createDirectory(at:setup,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            for name in ["sing-box.exe","install-relay.ps1"] {try FileManager.default.copyItem(at:self.payload.appendingPathComponent(name),to:setup.appendingPathComponent(name))}
            let client=try Self.json(self.root.appendingPathComponent("client-tun.json"))
            guard let outbound=(client["outbounds"] as? [[String:Any]])?.first,let key=outbound["password"] as? String else{throw Self.failure("Chiave del collegamento non disponibile.")}
            try Self.write(Self.server(key:key,addresses:selected),to:setup.appendingPathComponent("server.json"))
            try Data(request.utf8).write(to:setup.appendingPathComponent("package-id"))
            let iso=setup.appendingPathExtension("iso")
            _ = try await Self.run(URL(fileURLWithPath:"/usr/bin/hdiutil"),["makehybrid","-iso","-joliet","-default-volume-name","PERPNET","-o",iso.path,setup.path])
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:iso.path)
            _ = try await Self.run(self.root.appendingPathComponent("sing-box"),["check","-c",self.root.appendingPathComponent("client-tun.json").path])
            _ = try await self.qmp("blockdev-change-medium",["device":"bootstrap","filename":iso.path,"format":"raw"])
            try Self.write(["request":request,"iso":iso.path,"addresses":selected],to:self.root.appendingPathComponent("pending-install.json"))
            self.installationPending=true
            do {
                let id=self.machine!.configuration.id
                let launch=#"""
                $cd=@();for($i=0;$i -lt 20;$i++){$cd=@(Get-Volume|Where-Object FileSystemLabel -eq 'PERPNET');if($cd.Count -eq 1){break};Start-Sleep -Milliseconds 250};if($cd.Count -ne 1){throw 'Network setup CD missing'};
                $source=$cd[0].DriveLetter+':\';if([IO.File]::ReadAllText($source+'package-id') -ne '\#(request)'){throw 'Unexpected network setup CD'};
                $receipt=Join-Path $env:TEMP 'PerpendicularNetwork-\#(request).json';
                $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$source+'install-relay.ps1" -Source "'+$source.TrimEnd('\')+'" -ExpectedMachineID \#(id) -Receipt "'+$receipt+'"';
                $p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());
                if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -Wait}
                else{Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $arguments -Wait};'STARTED'
                """#
                _ = try await self.ps(launch)
            }catch{
                // A lost guest reply can follow a successful launch. Keep the
                // media and receipt identity until completion or explicit cancel.
                throw error
            }
            try await self.finishInstallation()
        }
    }
    func cancelInstallation(){
        guard installationPending,connected,!busy else{return}
        perform("Annullamento installazione…"){
            let path=self.root.appendingPathComponent("pending-install.json")
            let pending=try Self.json(path)
            guard let iso=pending["iso"] as? String,iso.hasPrefix(self.root.path+"/Setup-") else{throw Self.failure("Supporto di installazione non riconosciuto.")}
            try await self.eject(URL(fileURLWithPath:iso))
            try FileManager.default.removeItem(at:path);self.installationPending=false
            self.title="Installazione annullata";self.detail="Puoi ripetere l'installazione. Se Windows mostra ancora il consenso precedente, annullalo."
        }
    }
    private func finishInstallation()async throws {
        let journal=root.appendingPathComponent("pending-install.json")
        let pending=try Self.json(journal)
        guard let request=pending["request"] as? String,UUID(uuidString:request) != nil,
              let path=pending["iso"] as? String,path.hasPrefix(root.path+"/Setup-"),
              let selected=pending["addresses"] as? [String] else{throw Self.failure("Installazione sospesa non riconosciuta.")}
        let iso=URL(fileURLWithPath:path)
        var receipt:[String:Any]?
        for _ in 0..<60 {
            let text=try await ps(#"$p=Join-Path $env:TEMP 'PerpendicularNetwork-\#(request).json';if(Test-Path $p){Get-Content $p -Raw}else{'{}'}"#)
            if let data=text.data(using:.utf8),let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["ok"] is Bool {receipt=value;break}
            try await Task.sleep(for:.seconds(2))
        }
        guard let receipt else{throw Self.failure("Installazione ancora in attesa in Windows. Conferma il consenso, poi premi Completa installazione.")}
        try await eject(iso)
        try FileManager.default.removeItem(at:journal);installationPending=false
        guard receipt["ok"] as? Bool == true else{throw Self.failure(receipt["error"] as? String ?? "Installazione Windows non riuscita. Usa Installa o ripara.")}
        installed=true;savedAddresses=try Self.normalized(selected);addresses=savedAddresses;enabled=true;guestVerified=false
        try savePreferences();try await forwarding(true)
        if try await tunnel(){_ = try await tunnel(command:"reload")}
        else{_ = try await Self.run(root.appendingPathComponent("authorize"),[root.appendingPathComponent("supervisor").path,root.path])}
        try await Task.sleep(for:.seconds(1));try await probe()
    }
    private func perform(_ message:String,_ work:@escaping @MainActor ()async throws->Void){
        guard !busy else{return};busy=true;error=nil;title=message
        operation=Task{@MainActor [weak self] in
            guard let self else{return}
            defer{self.busy=false}
            do{
                for _ in 0..<120 {
                    if !self.checking,!self.guestBusy(){break}
                    try await Task.sleep(for:.seconds(1))
                }
                guard !self.checking,!self.guestBusy() else{throw Self.failure("Windows sta ancora preparando le cartelle. Riprova appena ha terminato.")}
                self.title=message
                try await work()
            }
            catch is CancellationError {self.title="In attesa di Windows"}
            catch{self.error=error.localizedDescription;self.title="Collegamento da verificare"}
        }
    }
    private func probe()async throws {
        guard installed else{title="Non installato";return}
        try verifyRuntime();tunnelActive=try await tunnel()
        let checkHash=guestVerified ? "$hash='verified'":"$hash=(Get-FileHash \"$d\\sing-box.exe\").Hash.ToLowerInvariant()"
        let script=#"""
        $d='C:\ProgramData\Perpendicular\HostVPN';$ok=Test-Path "$d\sing-box.exe";$hash='';if($ok){\#(checkHash)};
        $a=Get-NetAdapter -Name 'LinkManager Adapter' -ErrorAction SilentlyContinue;
        $t=Get-ScheduledTask -TaskName 'PerpendicularHostVPN' -ErrorAction SilentlyContinue;
        @{installed=$ok;hash=$hash;running=($t -and $t.State -eq 'Running');listening=([bool](Get-NetTCPConnection -LocalPort 10884 -State Listen -ErrorAction SilentlyContinue) -and [bool](Get-NetUDPEndpoint -LocalPort 10884 -ErrorAction SilentlyContinue));vpn=($a -and $a.Status -eq 'Up')}|ConvertTo-Json -Compress
        """#
        let text=try await ps(script)
        guard let data=text.data(using:.utf8),let state=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Self.failure("Windows non ha comunicato lo stato del collegamento.")}
        let pins=try Self.json(payload.appendingPathComponent("requirements.json"))["files"] as? [String:String] ?? [:]
        guard state["installed"] as? Bool == true,(state["hash"] as? String == pins["sing-box.exe"] || (guestVerified && state["hash"] as? String == "verified")) else{title="Componenti Windows da installare";detail="Usa Installa o ripara per preparare il collegamento.";return}
        guestVerified=true
        if !enabled {title="Disattivato";detail="Gli indirizzi restano salvati.";return}
        let listing=try await qmp("human-monitor-command",["command-line":"info usernet"]) as? String ?? ""
        let rows=Self.forwardRows(listing)
        let forwarding=rows.count==2
        try Self.write(["tunnel":tunnelActive,"forwarding":forwarding,"forwardRows":rows,"guest":state],to:root.appendingPathComponent("last-state.json"))
        if tunnelActive,forwarding,state["running"] as? Bool == true,state["listening"] as? Bool == true {
            title=state["vpn"] as? Bool == true ? "Attivo":"VPN Windows disconnessa"
            detail=state["vpn"] as? Bool == true ? "Le app del Mac possono usare gli indirizzi elencati.":"Connetti LinkManager in Windows per raggiungere i dispositivi."
        }else{title="Collegamento da riprendere";detail="Premi Riprendi inoltro per ripristinare il collegamento."}
    }
    private func installLocal(_ selected:[String])throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try Self.privateDirectory(root)
        let pins=try Self.json(payload.appendingPathComponent("requirements.json"))["files"] as? [String:String] ?? [:]
        for name in ["sing-box.exe","install-relay.ps1"] {
            guard Self.hash(try Data(contentsOf:payload.appendingPathComponent(name)))==pins[name] else{throw Self.failure("Il pacchetto di rete non corrisponde ai requisiti della build.")}
        }
        for name in ["sing-box","authorize","supervisor"] {
            let data=try Data(contentsOf:payload.appendingPathComponent(name))
            guard Self.hash(data)==pins[name] else{throw Self.failure("Il pacchetto di rete dell'app non è completo. Ricompila Perpendicular.")}
            try data.write(to:root.appendingPathComponent(name),options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.appendingPathComponent(name).path)
        }
        let path=root.appendingPathComponent("client-tun.json")
        if FileManager.default.fileExists(atPath:path.path) {
            let metadata=try Self.json(root.appendingPathComponent("connection.json"))
            guard metadata["machine_uuid"] as? String == machine!.configuration.id else{throw Self.failure("Il collegamento appartiene a un'altra macchina Windows.")}
            var client=try Self.json(path);var inbounds=client["inbounds"] as? [[String:Any]] ?? []
            guard inbounds.count==1 else{throw Self.failure("Configurazione del tunnel non riconosciuta.")}
            inbounds[0]["route_address"]=selected.map{$0+"/32"};client["inbounds"]=inbounds;try Self.write(client,to:path)
        }else {
            var bytes=[UInt8](repeating:0,count:32)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else{throw Self.failure("Non riesco a creare la chiave del collegamento.")}
            let key=Data(bytes).base64EncodedString()
            let client:[String:Any]=["log":["level":"warn","timestamp":true],"inbounds":[["type":"tun","tag":"vpn-tun","interface_name":"utun88","address":["198.18.88.1/30"],"mtu":1400,"auto_route":true,"route_address":selected.map{$0+"/32"},"dns_mode":"disabled","stack":"gvisor"]],"outbounds":[["type":"shadowsocks","tag":"windows-vpn","method":"2022-blake3-aes-256-gcm","password":key,"server":"127.0.0.1","server_port":10884,"multiplex":["enabled":true,"protocol":"smux","max_connections":1]]],"route":["final":"windows-vpn"]]
            try Self.write(client,to:path)
        }
        try Self.write(["machine_uuid":machine!.configuration.id,"targets":selected.map{$0+"/32"},"guest_ip":"10.0.2.15","host_port":10884,"guest_port":10884],to:root.appendingPathComponent("connection.json"))
    }
    private static func server(key:String,addresses:[String])->[String:Any] {
        ["log":["level":"warn","timestamp":true],"inbounds":[["type":"shadowsocks","tag":"host-in","listen":"10.0.2.15","listen_port":10884,"method":"2022-blake3-aes-256-gcm","password":key,"multiplex":["enabled":true]]],"outbounds":[["type":"direct","tag":"vpn","bind_interface":"LinkManager Adapter"]],"route":["rules":[["ip_cidr":addresses.map{$0+"/32"},"action":"route","outbound":"vpn"],["action":"reject"]]]]
    }
    private func verifyRuntime()throws {
        try Self.privateDirectory(root)
        let pins=try Self.json(payload.appendingPathComponent("requirements.json"))["files"] as? [String:String] ?? [:]
        let names=["sing-box","authorize","supervisor"]
        let stamp=try names.map {name in
            let a=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(name).path)
            return "\(name):\(a[.systemFileNumber] ?? ""):"+String(describing:a[.modificationDate])+String(describing:a[.size])
        }.joined(separator:"|")
        for name in names where stamp != runtimeStamp {
            guard Self.hash(try Data(contentsOf:root.appendingPathComponent(name)))==pins[name] else{throw Self.failure("I componenti di rete locali richiedono una riparazione.")}
        }
        runtimeStamp=stamp
        let metadata=try Self.json(root.appendingPathComponent("connection.json"))
        guard metadata["machine_uuid"] as? String==machine!.configuration.id else{throw Self.failure("Il collegamento appartiene a un'altra macchina Windows.")}
    }
    private func savePreferences()throws {try Self.write(["enabled":enabled,"addresses":savedAddresses],to:preferences)}
    private func ps(_ script:String)async throws->String {
        try Task.checkCancellation()
        guard connected,let bridge else{throw Self.failure("Collega Windows per continuare.")}
        let encoded=("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+script).data(using:.utf16LittleEndian)!.base64EncodedString()
        for attempt in 0..<5 {
            do {
                let packet:Data=try await withCheckedThrowingContinuation{continuation in
                    bridge.command("execute",["executable":#"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#,"args":["-NoProfile","-NonInteractive","-EncodedCommand",encoded],"timeoutSeconds":45],timeout:.seconds(50)){reply in
                        do{continuation.resume(returning:try JSONSerialization.data(withJSONObject:reply.get()))}
                        catch{continuation.resume(throwing:error)}
                    }
                }
                try Task.checkCancellation()
                let result=try JSONSerialization.jsonObject(with:packet) as? [String:Any] ?? [:]
                let value=result["value"] as? [String:Any] ?? [:]
                guard value["exitCode"] as? Int==0,value["timedOut"] as? Bool != true else{throw Self.failure("Windows non ha completato l'operazione di rete. Controlla i componenti o il consenso di installazione.")}
                return value["stdout"] as? String ?? ""
            }catch {
                if attempt<4,error.localizedDescription.contains("A command is already running") {try await Task.sleep(for:.seconds(2));continue}
                throw error
            }
        }
        throw Self.failure("Windows è occupato. Riprova tra qualche secondo.")
    }
    private func qmp(_ command:String,_ arguments:[String:Any]=[:])async throws->Any {
        guard let machine,case .running(let pid)=await machine.observedState() else{throw Self.failure("Windows deve essere acceso per collegare la rete.")}
        let socket=machine.controlSocket,id=machine.configuration.id
        let args=try JSONSerialization.data(withJSONObject:arguments)
        let data=try await Task.detached {
            let a=try JSONSerialization.jsonObject(with:args) as? [String:Any] ?? [:]
            let result=try MachineControl.value(socket:socket,operation:command,arguments:a,expectedUUID:id,expectedPID:pid)
            return try JSONSerialization.data(withJSONObject:result,options:.fragmentsAllowed)
        }.value
        try Task.checkCancellation();return try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)
    }
    private static func forwardRows(_ listing:String)->[[String]] {
        listing.split(whereSeparator:{$0.isNewline}).map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}.filter{row in
            row.count>=8 && row[0].contains("HOST_FORWARD") && Array(row.suffix(6).prefix(4))==["127.0.0.1","10884","10.0.2.15","10884"]
        }
    }
    private func forwarding(_ enabled:Bool)async throws {
        let listing=try await qmp("human-monitor-command",["command-line":"info usernet"]) as? String ?? ""
        for protocolName in ["tcp","udp"] {
            let exists=Self.forwardRows(listing).contains{$0[0].hasPrefix(protocolName.uppercased())}
            if exists==enabled {continue}
            let command=enabled ? "hostfwd_add net \(protocolName):127.0.0.1:10884-10.0.2.15:10884":"hostfwd_remove net \(protocolName):127.0.0.1:10884"
            let response=try await qmp("human-monitor-command",["command-line":command]) as? String ?? ""
            guard response.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw Self.failure("La porta locale del collegamento è occupata. Verifica la rete e riprova.")}
        }
    }
    private func eject(_ iso:URL)async throws {
        let blocks=try await qmp("query-block") as? [[String:Any]] ?? []
        if let cd=blocks.first(where:{$0["device"] as? String=="bootstrap"}),let inserted=cd["inserted"] as? [String:Any],inserted["file"] as? String==iso.path {_ = try await qmp("eject",["device":"bootstrap"])}
    }
    private func tunnel(command:String?=nil)async throws->Bool {
        let root=root
        let result=try await Task.detached {try Self.tunnelControl(root,command:command)}.value
        try Task.checkCancellation();return result
    }
    nonisolated private static func tunnelControl(_ root:URL,command:String?)throws->Bool {
        let path=root.appendingPathComponent("tun.sock").path
        var info=stat()
        guard lstat(path,&info)==0 else{return false}
        guard (info.st_mode & S_IFMT)==S_IFSOCK,info.st_uid==getuid(),info.st_mode & 0o777==0o600 else{throw failure("Il controllo del tunnel locale non è valido.")}
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{throw failure("Non riesco a controllare il tunnel.")};defer{close(fd)}
        var noSignal:Int32=1;_ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw failure("Il percorso del tunnel è troppo lungo.")}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let rc=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        if rc != 0 {
            if errno==ECONNREFUSED {
                var now=stat();if lstat(path,&now)==0,now.st_ino==info.st_ino {try FileManager.default.removeItem(atPath:path)}
                return false
            }
            throw failure("Il tunnel locale non risponde.")
        }
        var uid:uid_t=0,gid:gid_t=0
        guard getpeereid(fd,&uid,&gid)==0,uid==0 || uid==getuid() else{throw failure("Il supervisore del tunnel non è riconosciuto.")}
        if let command {
            let data=Array((command+"\n").utf8)
            guard data.withUnsafeBytes({send(fd,$0.baseAddress!,data.count,0)})==data.count else{throw failure("Non riesco a inviare il comando al tunnel.")}
            var timeout=timeval(tv_sec:3,tv_usec:0);_ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
            var reply=[UInt8](repeating:0,count:128)
            guard recv(fd,&reply,reply.count,0)>0 else{throw failure("Il supervisore non ha confermato il comando.")}
        }
        return true
    }
    nonisolated private static func run(_ executable:URL,_ args:[String])async throws->Data {
        let result=try await Task.detached {
            let process=Process();process.executableURL=executable;process.arguments=args
            let output=Pipe();process.standardOutput=output;process.standardError=output
            try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus==0 else{throw failure("Non riesco a preparare o autorizzare i componenti di rete. Riprova l'operazione.")}
            return data
        }.value
        try Task.checkCancellation();return result
    }
    nonisolated private static func privateDirectory(_ root:URL)throws {
        var info=stat();guard lstat(root.path,&info)==0,(info.st_mode & S_IFMT)==S_IFDIR,info.st_uid==getuid(),info.st_mode & 0o777==0o700 else{throw failure("La cartella privata del collegamento non è valida.")}
    }
    nonisolated private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    nonisolated private static func json(_ url:URL)throws->[String:Any] {
        guard let result=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else{throw failure("Configurazione di rete non valida.")};return result
    }
    nonisolated private static func write(_ value:[String:Any],to url:URL)throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    nonisolated private static func failure(_ text:String)->NSError {NSError(domain:"NetworkSettings",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
}
