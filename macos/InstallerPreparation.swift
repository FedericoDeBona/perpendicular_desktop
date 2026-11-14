import Foundation
import CryptoKit
import Darwin

struct InstallerState:Codable,Sendable {
    var phase:String
    var iso:String
    var imageName:String
    var startedAt:Date
    static func load(_ root:URL)->Self? {try? JSONDecoder().decode(Self.self,from:Data(contentsOf:root.appendingPathComponent("installation.json")))}
    func save(_ root:URL)throws {try JSONEncoder().encode(self).write(to:root.appendingPathComponent("installation.json"),options:.atomic)}
}

/// First installation never imports another machine's firmware variables or disk.
/// Preparation writes only into a newly reserved private machine directory.
enum InstallerPreparation {
    struct Image:Sendable {let index:Int;let name:String;let language:String}
    static func failure(_ message:String)->NSError {NSError(domain:"FirstRun",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    static func run(_ executable:String,_ arguments:[String],output:URL?=nil)throws->Data {
        let process=Process();process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
        let pipe=Pipe(),errors=Pipe();process.standardError=errors
        let file:FileHandle?
        if let output {
            FileManager.default.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600])
            file=try FileHandle(forWritingTo:output);process.standardOutput=file
        }else{file=nil;process.standardOutput=pipe}
        // Errors are sent to a file to avoid a full stderr pipe blocking a large media operation.
        let errorFile=FileManager.default.temporaryDirectory.appendingPathComponent("perpendicular-preparation-"+UUID().uuidString+".log")
        FileManager.default.createFile(atPath:errorFile.path,contents:nil,attributes:[.posixPermissions:0o600])
        let errorHandle=try FileHandle(forWritingTo:errorFile);process.standardError=errorHandle
        defer{try? errorHandle.close();try? FileManager.default.removeItem(at:errorFile);try? file?.close()}
        try process.run()
        let data=output == nil ? pipe.fileHandleForReading.readDataToEndOfFile():Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail=String(data:(try? Data(contentsOf:errorFile)) ?? Data(),encoding:.utf8) ?? ""
            throw failure(URL(fileURLWithPath:executable).lastPathComponent+": "+String(detail.suffix(1500)))
        }
        return data
    }
    static func image(in wim:URL)throws->Image {
        let file=try FileHandle(forReadingFrom:wim);defer{try? file.close()}
        guard let header=try file.read(upToCount:208),header.count==208,
              header.prefix(8)==Data([77,83,87,73,77,0,0,0]) else{throw failure("La ISO non contiene un'immagine Windows valida.")}
        func integer(_ offset:Int)->UInt64 {header.withUnsafeBytes{UInt64(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt64.self))}}
        let resource=integer(72),size=resource & 0x00ffffffffffffff,offset=integer(80),original=integer(88)
        let total=try file.seekToEnd()
        guard resource>>56 == 2,size==original,size<1_048_576,offset<=total,size<=total-offset else{throw failure("I metadati Windows della ISO non sono supportati.")}
        try file.seek(toOffset:offset)
        guard let xml=try file.read(upToCount:Int(size)),xml.count==Int(size) else{throw failure("Metadati Windows incompleti.")}
        let document=try XMLDocument(data:xml,options:.nodeLoadExternalEntitiesNever)
        let images=try document.nodes(forXPath:"/WIM/IMAGE")
        for case let element as XMLElement in images {
            let architecture=try element.nodes(forXPath:"WINDOWS/ARCH").first?.stringValue
            let edition=try element.nodes(forXPath:"WINDOWS/EDITIONID").first?.stringValue
            let build=Int(try element.nodes(forXPath:"WINDOWS/VERSION/BUILD").first?.stringValue ?? "") ?? 0
            if architecture=="12",edition=="IoTEnterpriseS",build>=26100,
               let index=Int(element.attribute(forName:"INDEX")?.stringValue ?? ""),index>0 {
                let name=try element.nodes(forXPath:"NAME").first?.stringValue ?? "Windows 11 IoT Enterprise LTSC"
                let language=try element.nodes(forXPath:"WINDOWS/LANGUAGES/DEFAULT").first?.stringValue ?? "en-US"
                guard language.range(of:"^[a-z]{2}-[A-Z]{2}$",options:.regularExpression) != nil else{throw failure("Lingua della ISO non supportata.")}
                return Image(index:index,name:name,language:language)
            }
        }
        throw failure("Questa prima versione richiede una ISO Windows 11 IoT Enterprise LTSC 2024 ARM64. La ISO scelta non contiene questa edizione.")
    }
    static func xml(_ value:String)->String {value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;")}
    static func answer(image:Image,password:String)->String {
        func component(_ name:String,_ content:String)->String {"<component name=\"\(name)\" processorArchitecture=\"arm64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\(content)</component>"}
        let language="<InputLocale>0409:00000409</InputLocale><SystemLocale>\(image.language)</SystemLocale><UILanguage>\(image.language)</UILanguage><UserLocale>\(image.language)</UserLocale>"
        let setup="""
        <UserData><AcceptEula>true</AcceptEula><FullName>Perpendicular</FullName><Organization>Perpendicular</Organization></UserData>
        <DynamicUpdate><Enable>false</Enable></DynamicUpdate>
        <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions>
        <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
        <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
        <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
        </CreatePartitions><ModifyPartitions>
        <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
        <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
        </ModifyPartitions></Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
        <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>\(image.index)</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
        """
        let command="cmd.exe /c for %d in (D E F G H I J K L M N O P) do @if exist %d:\\Perpendicular\\Install-System.ps1 powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %d:\\Perpendicular\\Install-System.ps1"
        let deployment="<RunSynchronous><RunSynchronousCommand wcm:action=\"add\"><Order>1</Order><Path>\(xml(command))</Path><Description>Install Perpendicular drivers</Description></RunSynchronousCommand></RunSynchronous>"
        let shell="""
        <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
        <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>Perpendicular</Name><DisplayName>Perpendicular</DisplayName><Group>Administrators</Group><Password><Value>\(xml(password))</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
        <AutoLogon><Username>Perpendicular</Username><Enabled>true</Enabled><LogonCount>3</LogonCount><Password><Value>\(xml(password))</Value><PlainText>true</PlainText></Password></AutoLogon>
        <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\ProgramData\\Perpendicular\\Setup\\Complete-User.ps1</CommandLine><Description>Complete Perpendicular installation</Description></SynchronousCommand></FirstLogonCommands>
        """
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><unattend xmlns=\"urn:schemas-microsoft-com:unattend\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\"><settings pass=\"windowsPE\">"+component("Microsoft-Windows-International-Core-WinPE","<SetupUILanguage><UILanguage>\(image.language)</UILanguage></SetupUILanguage>"+language)+component("Microsoft-Windows-Setup",setup)+"</settings><settings pass=\"specialize\">"+component("Microsoft-Windows-Shell-Setup","<ComputerName>PERP-WINDOWS</ComputerName><TimeZone>UTC</TimeZone>")+component("Microsoft-Windows-Deployment",deployment)+"</settings><settings pass=\"oobeSystem\">"+component("Microsoft-Windows-International-Core",language)+component("Microsoft-Windows-Shell-Setup",shell)+"</settings></unattend>"
    }
    /// Microsoft includes an otherwise equivalent no-prompt EFI boot image.
    /// Replace only the verified El Torito extent in a private copy, never the source ISO.
    static func automaticISO(source:URL,mounted:URL,root:URL)throws->URL {
        let boot=mappedBootImages(mounted)
        let original=try Data(contentsOf:boot.0),replacement=try Data(contentsOf:boot.1)
        guard original.count==replacement.count,original.count>0,original.count<=16_777_216 else{throw failure("La ISO non contiene un avvio automatico compatibile.")}
        let input=try FileHandle(forReadingFrom:source);defer{try? input.close()}
        var catalogOffset:UInt64?
        for sector in 16..<40 {
            try input.seek(toOffset:UInt64(sector*2048))
            guard let data=try input.read(upToCount:2048),data.count==2048 else{break}
            if data[0]==0,String(data:data[1..<6],encoding:.ascii)=="CD001",
               String(data:data[7..<39],encoding:.ascii)?.trimmingCharacters(in:CharacterSet(charactersIn:"\0 "))=="EL TORITO SPECIFICATION" {
                catalogOffset=UInt64(data.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:71,as:UInt32.self))})*2048;break
            }
        }
        guard let catalogOffset else{throw failure("Catalogo di avvio ISO mancante.")}
        try input.seek(toOffset:catalogOffset)
        guard let catalog=try input.read(upToCount:64),catalog.count==64,catalog[0]==1,catalog[1]==0xef,catalog[30]==0x55,catalog[31]==0xaa,catalog[32]==0x88 else{throw failure("Il catalogo di avvio ARM64 della ISO non è supportato.")}
        let offset=UInt64(catalog.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:40,as:UInt32.self))})*2048
        try input.seek(toOffset:offset)
        guard try input.read(upToCount:original.count)==original else{throw failure("L'immagine di avvio della ISO differisce dal suo catalogo.")}
        let destination=root.appendingPathComponent("installation-windows.iso")
        // clonefile uses an APFS copy-on-write clone; fallback is a normal private copy.
        let result=source.path.withCString{from in destination.path.withCString{to in clonefile(from,to,0)}}
        if result != 0 {try FileManager.default.copyItem(at:source,to:destination)}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        let output=try FileHandle(forUpdating:destination);defer{try? output.close()}
        try output.seek(toOffset:offset);try output.write(contentsOf:replacement);try output.synchronize()
        try JSONSerialization.data(withJSONObject:["schema":1,"offset":offset,"bytes":original.count,"originalEFI":SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined(),"automaticEFI":SHA256.hash(data:replacement).map{String(format:"%02x",$0)}.joined(),"sourceModified":false],options:.prettyPrinted).write(to:root.appendingPathComponent("boot-media-receipt.json"))
        return destination
    }
    private static func mappedBootImages(_ root:URL)->(URL,URL) {(root.appendingPathComponent("efi/microsoft/boot/efisys.bin"),root.appendingPathComponent("efi/microsoft/boot/efisys_noprompt.bin"))}
    static func random()->String {UUID().uuidString.replacingOccurrences(of:"-",with:"")+UUID().uuidString.replacingOccurrences(of:"-",with:"")}
    static func prepare(iso:URL,root:URL,contents:URL)throws {
        let fm=FileManager.default
        guard !fm.fileExists(atPath:root.appendingPathComponent("machine.json").path),!fm.fileExists(atPath:root.appendingPathComponent("Windows").path) else{throw failure("Questa cartella contiene già Windows. Nessun file è stato sovrascritto.")}
        guard iso.isFileURL,iso.pathExtension.lowercased()=="iso",!iso.path.contains(","),!root.path.contains(",") else{throw failure("Scegli un file ISO locale con un percorso senza virgole.")}
        let payload=contents.appendingPathComponent("Resources/FirstRun")
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:payload.appendingPathComponent("manifest.json"))) as? [String:Any]
        guard let files=manifest?["files"] as? [String:String],let firmware=manifest?["firmware"] as? [String:String] else{throw failure("Il pacchetto di prima installazione è incompleto.")}
        for (name,hash) in files {
            guard !name.hasPrefix("/"),!name.split(separator:"/").contains(".."),SHA256.hash(data:try Data(contentsOf:payload.appendingPathComponent(name))).map({String(format:"%02x",$0)}).joined()==hash else{throw failure("Un componente di installazione è danneggiato: "+name)}
        }
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let available=try root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available>=17_179_869_184 else{throw failure("Servono almeno 16 GB liberi per questa installazione. Libera spazio prima di riprovare.")}
        let mount=try PropertyListSerialization.propertyList(from:run("/usr/bin/hdiutil",["attach","-readonly","-nobrowse","-plist",iso.path]),format:nil) as? [String:Any]
        guard let entities=mount?["system-entities"] as? [[String:Any]],let path=entities.compactMap({$0["mount-point"] as? String}).first else{throw failure("Non riesco ad aprire la ISO.")}
        let source=URL(fileURLWithPath:path);defer{_ = try? run("/usr/bin/hdiutil",["detach",path])}
        guard fm.fileExists(atPath:source.appendingPathComponent("efi/boot/bootaa64.efi").path) else{throw failure("La ISO non avvia Windows ARM64.")}
        let selected=try image(in:source.appendingPathComponent("sources/install.wim"))
        let bootISO=try automaticISO(source:iso,mounted:source,root:root)
        let windows=root.appendingPathComponent("Windows"),media=root.appendingPathComponent("InstallationMedia")
        try fm.createDirectory(at:windows.appendingPathComponent("tpm"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try fm.createDirectory(at:media.appendingPathComponent("Perpendicular"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        for (name,target) in [("code","efi-code.fd"),("variables","efi-vars.fd")] {
            let destination=windows.appendingPathComponent(target)
            _=try run("/usr/bin/gzip",["-dc",payload.appendingPathComponent(name+".fd.gz").path],output:destination)
            guard SHA256.hash(data:try Data(contentsOf:destination,options:.mappedIfSafe)).map({String(format:"%02x",$0)}).joined()==firmware[name] else{throw failure("Firmware estratto non valido.")}
        }
        _=try run(contents.appendingPathComponent("Resources/QEMU/bin/qemu-img").path,["create","-f","qcow2",windows.appendingPathComponent("system.qcow2").path,"80G"])
        let password="Pp!"+random()
        try Data(answer(image:selected,password:password).utf8).write(to:media.appendingPathComponent("Autounattend.xml"))
        for file in try fm.contentsOfDirectory(at:payload,includingPropertiesForKeys:nil) where !["code.fd.gz","variables.fd.gz","manifest.json"].contains(file.lastPathComponent) {
            try fm.copyItem(at:file,to:media.appendingPathComponent("Perpendicular/"+file.lastPathComponent))
        }
        try fm.copyItem(at:contents.appendingPathComponent("Resources/Guest"),to:media.appendingPathComponent("Perpendicular/Guest"))
        let token=random(),port:UInt16=try freePort(),id=UUID().uuidString.lowercased()
        try JSONSerialization.data(withJSONObject:["port":port,"token":token]).write(to:media.appendingPathComponent("Perpendicular/Guest/connection.json"))
        try JSONSerialization.data(withJSONObject:["password":password]).write(to:media.appendingPathComponent("Perpendicular/secrets.json"))
        let answerISO=root.appendingPathComponent("installation-answer.iso")
        _=try run("/usr/bin/hdiutil",["makehybrid","-iso","-joliet","-default-volume-name","PERPSETUP","-o",answerISO.path,media.path])
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:answerISO.path)
        let machine:[String:Any]=["id":id,"name":"Windows","cpus":min(4,ProcessInfo.processInfo.processorCount),"memoryMiB":4096,"disk":windows.appendingPathComponent("system.qcow2").path,"firmware":windows.appendingPathComponent("efi-code.fd").path,"variables":windows.appendingPathComponent("efi-vars.fd").path,"mac":"02:"+id.replacingOccurrences(of:"-",with:"").prefix(10).enumerated().reduce(into:""){s,v in if v.offset>0 && v.offset%2==0{s+=":"};s.append(v.element)},"guestPort":port,"token":token,"graphics":"native3D","mixedDisplays":true,"keyboardLayout":"en-us","sharedFolders":["folders":[]],"installationISO":bootISO.path,"installationAnswer":answerISO.path]
        try JSONSerialization.data(withJSONObject:machine,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("machine.json"),options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("machine.json").path)
        try InstallerState(phase:"installing",iso:iso.path,imageName:selected.name,startedAt:Date()).save(root)
    }
    static func freePort()throws->UInt16 {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else{throw failure("Non riesco a preparare la connessione Windows.")};defer{close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard result==0 else{throw failure("Connessione Windows non disponibile.")}
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        let read=withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}}
        guard read==0 else{throw failure("Connessione Windows non disponibile.")};return UInt16(bigEndian:address.sin_port)
    }
}
