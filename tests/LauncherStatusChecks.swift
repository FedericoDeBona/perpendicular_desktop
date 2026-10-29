import Foundation

@main struct LauncherStatusChecks {
    static func main(){
        precondition(LauncherWindowsStatus.resolve(running:false).title == "Spento")
        precondition(LauncherWindowsStatus.resolve(running:true,awaitingGuest:true).title == "In avvio","A live process alone does not complete boot")
        precondition(LauncherWindowsStatus.resolve(running:true).kind == .preparing,"Attaching a frontend is not a lost connection")
        precondition(LauncherWindowsStatus.resolve(running:true,connected:true,appsReady:false).title == "Preparazione app")
        precondition(LauncherWindowsStatus.resolve(running:true,connected:true,appsReady:true).title == "Acceso")
        precondition(LauncherWindowsStatus.resolve(running:true,contactEstablished:true).kind == .disconnected)
        precondition(LauncherWindowsStatus.resolve(running:nil).kind == .unknown)
        let warning=LauncherWindowsStatus.resolve(running:true,connected:true,appsReady:true,warning:("Cartelle non collegate","Errore concreto"))
        precondition(warning.kind == .attention && warning.detail == "Errore concreto")
        precondition(LauncherWindowsStatus.resolve(running:true,connected:true,appsReady:true,imageError:"Cattura assente").kind == .graphics)
        precondition(LauncherWindowsStatus.resolve(running:false,operation:"Avvio di Windows…").kind == .starting)
        print("Launcher status: boot, readiness, reconnect and warning boundaries passed")
    }
}
