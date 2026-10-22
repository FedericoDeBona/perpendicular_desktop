import AppKit
import SwiftUI

extension Notification.Name {
    static let launcherFocusSearch=Notification.Name("PerpendicularLauncherFocusSearch")
}

@MainActor
struct Launcher:View {
    @ObservedObject var model:ApplicationModel
    @State private var search=""
    @State private var layout=0
    @FocusState private var searchFocused:Bool

    private var results:[WindowsApplication] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        return query.isEmpty ? model.apps:model.apps.filter{$0.name.localizedStandardContains(query)}
    }

    var body:some View {
        VStack(spacing:0){
            VStack(alignment:.leading,spacing:22){
                HStack(alignment:.center,spacing:20){
                    VStack(alignment:.leading,spacing:6){
                        Text("PERPENDICULAR").font(.system(size:10,weight:.semibold)).tracking(2).foregroundStyle(.secondary)
                        Text("Le tue app Windows").font(.system(size:27,weight:.semibold))
                        Text("Si aprono in finestre sul Mac.").font(.system(size:13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                    Button{model.showProcesses()}label:{Label("Processi",systemImage:"waveform.path.ecg")}
                        .disabled(!model.connected)
                    Button(action:model.showWindows){Label("Apri Windows",systemImage:"desktopcomputer")}
                        .controlSize(.large).disabled(!model.desktopAvailable || model.machineOperation != nil)
                        .help("Apri il desktop Windows, anche durante la riconnessione")
                }
                HStack(spacing:12){
                    Circle().fill(model.machineState == .stopped ? Color.secondary:Color.accentColor).frame(width:6,height:6)
                    Text(model.machineStateLabel).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityIdentifier("windowsMachineState")
                    Spacer(minLength:0)
                    if model.machineOperation != nil {ProgressView().controlSize(.small)}
                    Button("Avvia Windows",action:model.startWindows).disabled(!model.canStartWindows)
                    Button("Arresto forzato…",role:.destructive,action:model.forceStopWindows).disabled(!model.canStopWindows)
                        .help("Interrompe la VM anche se Windows o il guest agent non rispondono")
                }
                HStack(spacing:12){
                    HStack(spacing:9){
                        Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                        TextField("Cerca un’app",text:$search).textFieldStyle(.plain)
                            .focused($searchFocused).onSubmit{if let app=results.first {model.launch(app)}}
                            .accessibilityLabel("Cerca nelle applicazioni Windows")
                        if !search.isEmpty {
                            Button{search="";searchFocused=true}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}
                                .buttonStyle(.plain).help("Cancella ricerca").accessibilityLabel("Cancella ricerca")
                        }
                    }
                    .font(.system(size:14)).padding(.horizontal,12).padding(.vertical,11)
                    .background(.background,in:RoundedRectangle(cornerRadius:10))
                    .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(searchFocused ? Color.accentColor.opacity(0.6):Color.primary.opacity(0.1),lineWidth:1))
                    Picker("Visualizzazione",selection:$layout){
                        Image(systemName:"square.grid.2x2").tag(0)
                        Image(systemName:"list.bullet").tag(1)
                    }.pickerStyle(.segmented).labelsHidden().frame(width:78).help("Griglia o elenco")
                    Button(action:model.refresh){
                        if model.catalogueLoading {ProgressView().controlSize(.small).frame(width:16,height:16)}
                        else {Image(systemName:"arrow.clockwise").frame(width:16,height:16)}
                    }.buttonStyle(.borderless).disabled(!model.connected || model.catalogueLoading)
                        .help("Aggiorna elenco").accessibilityLabel("Aggiorna elenco")
                }
            }.padding(24)
            if let notice=model.launcherNotice {
                HStack(alignment:.top,spacing:10){
                    Image(systemName:"exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(notice).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Button{model.launcherNotice=nil}label:{Image(systemName:"xmark").font(.system(size:10,weight:.semibold))}
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Chiudi messaggio")
                }.padding(12).background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
                    .padding(.horizontal,24).padding(.bottom,14)
            }
            HStack{
                Text(search.isEmpty ? "Tutte le app":"Risultati della ricerca").font(.system(size:12,weight:.semibold))
                Text("\(results.count)").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal,7).padding(.vertical,2).background(.quaternary,in:Capsule())
                Spacer()
                if !model.connected && !model.apps.isEmpty && model.machineState != .stopped {Text("In attesa di Windows…").font(.caption).foregroundStyle(.secondary)}
            }.padding(.horizontal,26).padding(.bottom,12)
            if results.isEmpty {emptyState.frame(maxWidth:.infinity,maxHeight:.infinity)}
            else {
                ScrollView{
                    if layout==0 {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:148,maximum:210),spacing:12)],spacing:12){
                            ForEach(results){app in application(app,compact:false)}
                        }.padding(.horizontal,24).padding(.bottom,24)
                    }else{
                        LazyVStack(spacing:6){ForEach(results){app in application(app,compact:true)}}
                            .padding(.horizontal,24).padding(.bottom,24)
                    }
                }
            }
            Divider()
            HStack(spacing:7){
                Circle().fill(model.machineState == .stopped ? Color.secondary:model.connected ? Color.green:Color.orange).frame(width:6,height:6)
                Text(model.machineStateLabel)
                Spacer()
                if !model.openingApps.isEmpty {Text("Apertura in corso…")}
                else if !model.activeApps.isEmpty {Text(model.activeApps.count == 1 ? "1 app aperta":"\(model.activeApps.count) app aperte")}
                else {Text("⌘F per cercare · Invio per aprire")}
            }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,13)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .frame(minWidth:600,minHeight:440)
        .background(Button(""){searchFocused=true}.keyboardShortcut("f",modifiers:.command).hidden())
        .sheet(isPresented:$model.processPanelVisible){GuestProcessesPanel(model:model)}
        .onAppear{searchFocused=true}
        .onReceive(NotificationCenter.default.publisher(for:.launcherFocusSearch)){_ in searchFocused=true}
        .onExitCommand{if !search.isEmpty {search="";searchFocused=true}}
    }

    private func application(_ app:WindowsApplication,compact:Bool)->some View {
        LauncherApplication(app:app,icon:model.applicationIcons[app.id],compact:compact,
            opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),stateLabel:model.applicationStateLabel(app.id),
            loadingIcon:model.loadingIconID == app.id,connected:model.connected){model.launch(app)}
            .contextMenu{
                Button("Mostra processi"){model.showProcesses(for:app.id)}
                Button("Chiudi finestre"){model.closeApplication(app)}.disabled(!model.activeApps.contains(app.id))
            }
            .onAppear{model.applicationBecameVisible(app)}
            .onDisappear{model.applicationBecameHidden(app)}
    }

    @ViewBuilder private var emptyState:some View {
        VStack(spacing:13){
            if !model.desktopAvailable {
                Image(systemName:"exclamationmark.triangle").font(.system(size:30,weight:.light)).foregroundStyle(.tertiary)
                Text("Windows non è disponibile").font(.system(size:18,weight:.semibold))
                Text("Controlla il messaggio qui sopra per continuare.").foregroundStyle(.secondary)
            }else if model.machineState == .stopped {
                Image(systemName:"power").font(.system(size:30,weight:.light)).foregroundStyle(.tertiary)
                Text("Windows è spento").font(.system(size:18,weight:.semibold))
                Text("Premi Avvia Windows per usare le tue app.").foregroundStyle(.secondary)
            }else if model.apps.isEmpty && (!model.connected || model.catalogueLoading) {
                ProgressView().controlSize(.regular).padding(.bottom,4)
                Text(model.connected ? "Cerco le tue app…":"Windows si sta collegando").font(.system(size:18,weight:.semibold))
                Text("Puoi aprire il desktop Windows mentre aspetti.").foregroundStyle(.secondary)
            }else if !search.isEmpty {
                Image(systemName:"magnifyingglass").font(.system(size:30,weight:.light)).foregroundStyle(.tertiary)
                Text("Nessun risultato").font(.system(size:18,weight:.semibold))
                Text("Prova un altro nome o cancella la ricerca.").foregroundStyle(.secondary)
                Button("Cancella ricerca"){search="";searchFocused=true}.padding(.top,2)
            }else{
                Image(systemName:"square.grid.2x2").font(.system(size:30,weight:.light)).foregroundStyle(.tertiary)
                Text("Nessuna app trovata").font(.system(size:18,weight:.semibold))
                Text("Aggiorna l’elenco o apri Windows per installare un’app.").foregroundStyle(.secondary)
                Button("Aggiorna elenco",action:model.refresh).disabled(!model.connected)
            }
        }.font(.system(size:13)).multilineTextAlignment(.center).padding(30)
    }
}

@MainActor
private struct LauncherApplication:View {
    let app:WindowsApplication
    let icon:NSImage?
    let compact:Bool
    let opening:Bool
    let active:Bool
    let stateLabel:String
    let loadingIcon:Bool
    let connected:Bool
    let action:()->Void
    @State private var hovered=false

    var body:some View {
        Button(action:action){
            Group{
                if compact {
                    HStack(spacing:14){
                        applicationIcon.frame(width:40,height:40)
                        Text(app.name).font(.system(size:13,weight:.medium)).lineLimit(1)
                        Spacer(minLength:12)
                        state
                    }.padding(.horizontal,14).padding(.vertical,11)
                }else{
                    VStack(spacing:10){
                        applicationIcon.frame(width:56,height:56)
                        Text(app.name).font(.system(size:13,weight:.medium)).multilineTextAlignment(.center)
                            .lineLimit(2).frame(height:34,alignment:.top).frame(maxWidth:.infinity)
                        state.frame(height:14)
                    }.padding(.horizontal,12).padding(.vertical,16)
                }
            }
            .foregroundStyle(.primary)
            .background(hovered && connected ? Color.accentColor.opacity(0.07):Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(hovered && connected ? Color.accentColor.opacity(0.35):Color.primary.opacity(0.07),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:12))
        }
        .buttonStyle(.plain).disabled(!connected || opening)
        .opacity(connected ? 1:0.58)
        .onHover{hovered=$0}
        .help(opening ? "Apertura di \(app.name)…":active ? "Mostra \(app.name)":"Apri \(app.name)")
        .accessibilityLabel(app.name)
        .accessibilityValue(stateLabel)
    }

    @ViewBuilder private var applicationIcon:some View {
        if let icon {Image(nsImage:icon).resizable().interpolation(.high).scaledToFit()}
        else {
            RoundedRectangle(cornerRadius:compact ? 8:12).fill(Color.primary.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius:compact ? 8:12).strokeBorder(Color.primary.opacity(0.07),lineWidth:1))
                .overlay{if loadingIcon {ProgressView().controlSize(.small)}}
                .accessibilityHidden(true)
        }
    }

    private var state:some View {
        HStack(spacing:5){
            if opening {ProgressView().controlSize(.mini)}
            else if active {Circle().fill(Color.green).frame(width:5,height:5)}
            Text(stateLabel).lineLimit(2)
        }.font(.system(size:11)).foregroundStyle(hovered && connected ? Color.accentColor:Color.secondary)
    }
}
