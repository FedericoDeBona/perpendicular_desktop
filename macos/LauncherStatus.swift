import SwiftUI

struct LauncherWindowsStatus {
    enum Kind {case off,starting,preparing,connected,stopping,restarting,busy,attention,graphics,disconnected,unknown}
    let kind:Kind
    let title:String
    let detail:String
    var symbol:String {switch kind {
        case .off:"power";case .starting:"power.circle.fill";case .preparing:"square.grid.2x2.fill"
        case .connected:"checkmark.circle.fill";case .stopping:"stop.circle";case .restarting:"arrow.clockwise.circle"
        case .busy:"hourglass";case .attention:"exclamationmark.triangle.fill"
        case .graphics:"exclamationmark.octagon.fill";case .disconnected:"network.slash";case .unknown:"questionmark.circle"
    }}
    var color:Color {switch kind {
        case .off,.stopping:.secondary;case .connected:.green;case .starting,.restarting,.busy:.blue
        case .preparing:.indigo;case .attention,.disconnected,.unknown:.orange;case .graphics:.red
    }}
    var working:Bool {switch kind {case .starting,.preparing,.stopping,.restarting,.busy:true;default:false}}
    var needsAttention:Bool {switch kind {case .attention,.graphics,.disconnected,.unknown:true;default:false}}

    /// Process state, guest contact and app readiness are separate facts.
    static func resolve(running:Bool?,operation:String?=nil,restarting:Bool=false,
                        connected:Bool=false,awaitingGuest:Bool=false,contactEstablished:Bool=false,
                        appsReady:Bool=false,imageError:String?=nil,warning:(title:String,detail:String)?=nil)->Self {
        if let operation {
            if operation == "Avvio di Windows…" {return .init(kind:.starting,title:"In avvio",detail:"Avvio di Windows in corso.")}
            if operation == "Richiesta di spegnimento…" || operation == "Arresto forzato di Windows…" {
                return .init(kind:.stopping,title:"Spegnimento",detail:operation)
            }
            if operation == "Apertura desktop Windows…" {return .init(kind:.preparing,title:"Preparazione desktop",detail:operation)}
            return .init(kind:.busy,title:"Aggiornamento impostazioni",detail:operation)
        }
        if restarting {return .init(kind:.restarting,title:"Riavvio",detail:"Attendo il nuovo collegamento con Windows.")}
        guard let running else {return .init(kind:.unknown,title:"Stato sconosciuto",detail:"Non riesco a verificare se Windows è acceso o spento.")}
        guard running else {return .init(kind:.off,title:"Spento",detail:"Windows è spento.")}
        if !connected {
            if awaitingGuest {return .init(kind:.starting,title:"In avvio",detail:"Windows è in esecuzione; attendo il collegamento iniziale.")}
            if !contactEstablished {return .init(kind:.preparing,title:"Preparazione app",detail:"Collegamento alle app di Windows in corso.")}
            return .init(kind:.disconnected,title:"Collegamento perso",detail:"Windows è ancora acceso. Sto ripristinando il collegamento alle app.")
        }
        if let imageError {return .init(kind:.graphics,title:"Problema immagine",detail:imageError)}
        if let warning {return .init(kind:.attention,title:warning.title,detail:warning.detail)}
        if !appsReady {return .init(kind:.preparing,title:"Preparazione app",detail:"Windows è collegato; preparo le finestre delle app.")}
        return .init(kind:.connected,title:"Acceso",detail:"Windows è acceso e le app sono disponibili.")
    }
}
