import AppKit
import SwiftUI

extension Notification.Name {
    static let launcherFocusSearch=Notification.Name("PerpendicularLauncherFocusSearch")
}

private enum LibrarySection:String,CaseIterable,Identifiable {
    case home="Per te",recent="Recenti",all="Tutte le app",displays="Schermi"
    var id:Self {self}
    var symbol:String {switch self {case .home:"square.grid.2x2";case .recent:"clock";case .all:"square.stack.3d.up";case .displays:"display.2"}}
}

@MainActor
struct Launcher:View {
    @ObservedObject var model:ApplicationModel
    @State private var search=""
    @State private var section=LibrarySection.home
    @FocusState private var searchFocused:Bool
    private var results:[WindowsApplication] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        if !query.isEmpty {return model.apps.filter{$0.matches(query)}}
        switch section {
        case .home:return model.launcherPreferences.suggested(model.apps)
        case .recent:return model.launcherPreferences.recent(model.apps)
        case .all:return model.apps
        case .displays:return []
        }
    }
    var body:some View {
        HStack(spacing:0){
            sidebar
            Divider().opacity(0.45)
            VStack(alignment:.leading,spacing:0){
                HStack(spacing:24){
                    Text(search.isEmpty ? section.rawValue:"Risultati").font(.system(size:27,weight:.semibold,design:.rounded)).tracking(-0.6)
                    Spacer(minLength:8)
                    searchField.frame(width:240)
                }.padding(.horizontal,32).padding(.top,28).padding(.bottom,26)
                if let notice=model.launcherNotice {
                    HStack(spacing:10){
                        Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                        Text(notice).font(.system(size:12)).lineLimit(3)
                        Spacer()
                        Button{model.launcherNotice=nil}label:{Image(systemName:"xmark").font(.system(size:10,weight:.medium))}.buttonStyle(.plain)
                    }.padding(12).background(.orange.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
                        .padding(.horizontal,32).padding(.bottom,18)
                }
                if section == .displays && search.isEmpty {displays}
                else if results.isEmpty {
                    VStack(spacing:14){
                        if model.catalogueLoading {ProgressView().controlSize(.regular)}
                        else {
                            Image(systemName:section == .recent && search.isEmpty ? "clock":"magnifyingglass").font(.system(size:32,weight:.ultraLight)).foregroundStyle(.tertiary)
                            Text(section == .recent && search.isEmpty ? "Nessuna app recente":"Nessuna app").font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }else{
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:112,maximum:145),spacing:18)],alignment:.leading,spacing:22){
                            ForEach(results){app in
                                LibraryAppTile(app:app,icon:model.applicationIcons[app.id],opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),enabled:model.connected){model.launch(app)}
                                    .contextMenu{
                                        Button(model.launcherPreferences.pinned.contains(app.id) ? "Rimuovi dai preferiti":"Aggiungi ai preferiti"){model.togglePin(app)}
                                        Divider()
                                        Button("Mostra processi"){model.showProcesses(for:app.id)}
                                        Button("Chiudi finestre"){model.closeApplication(app)}.disabled(!model.activeApps.contains(app.id))
                                    }
                                    .onAppear{model.applicationBecameVisible(app)}
                                    .onDisappear{model.applicationBecameHidden(app)}
                            }
                        }.padding(.horizontal,26).padding(.bottom,32)
                    }
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(Color(nsColor:.controlBackgroundColor).opacity(0.45))
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .frame(minWidth:800,minHeight:510)
        .background(Button(""){searchFocused=true}.keyboardShortcut("f",modifiers:.command).hidden())
        .sheet(isPresented:$model.processPanelVisible){GuestProcessesPanel(model:model)}
        .onAppear{searchFocused=true}
        .onReceive(NotificationCenter.default.publisher(for:.launcherFocusSearch)){_ in searchFocused=true}
        .onExitCommand{if !search.isEmpty {search=""}}
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0){
            HStack(spacing:10){
                Image(systemName:"square.stack.3d.up.fill").font(.system(size:22,weight:.medium)).foregroundStyle(.indigo)
                Text("Perpendicular").font(.system(size:14,weight:.semibold))
            }.padding(.horizontal,20).padding(.top,30).padding(.bottom,34)
            VStack(spacing:5){
                ForEach(LibrarySection.allCases){item in
                    Button{section=item;search=""}label:{
                        HStack(spacing:11){
                            Image(systemName:item.symbol).font(.system(size:15,weight:.medium)).frame(width:20)
                            Text(item.rawValue).font(.system(size:13,weight:section == item ? .semibold:.medium))
                            Spacer()
                        }.foregroundStyle(section == item ? Color.indigo:Color.primary.opacity(0.72))
                            .padding(.horizontal,13).padding(.vertical,11)
                            .background(section == item ? Color.indigo.opacity(0.09):.clear,in:RoundedRectangle(cornerRadius:10))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal,12)
            Spacer(minLength:24)
            Button(action:model.showWindows){
                HStack(spacing:10){Image(systemName:"macwindow").font(.system(size:15));Text("Apri Windows").font(.system(size:12,weight:.medium)).lineLimit(1).fixedSize();Spacer();Image(systemName:"arrow.up.right").font(.system(size:10,weight:.semibold))}
                    .foregroundStyle(.primary).padding(13)
                    .background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
            }.buttonStyle(.plain).disabled(!model.desktopAvailable || model.machineOperation != nil).padding(.horizontal,12).padding(.bottom,17)
            HStack(spacing:8){
                Circle().fill(model.connected ? Color.green:Color.secondary.opacity(0.5)).frame(width:6,height:6)
                Text("Windows").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                Spacer()
                if model.machineOperation != nil {ProgressView().controlSize(.mini)}
                Menu {
                    Button("Aggiorna app",action:model.refresh).disabled(!model.connected || model.catalogueLoading)
                    Button("Processi"){model.showProcesses()}.disabled(!model.connected)
                    Divider()
                    Button("Avvia Windows",action:model.startWindows).disabled(!model.canStartWindows)
                    Button("Spegni Windows",action:model.shutdownWindows).disabled(!model.canStopWindows)
                    Button("Arresto forzato…",role:.destructive,action:model.forceStopWindows).disabled(!model.canStopWindows)
                }label:{Image(systemName:"ellipsis").font(.system(size:16)).frame(width:18,height:18)}
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.padding(.horizontal,23).padding(.bottom,22)
        }.frame(width:196).frame(maxHeight:.infinity)
    }
    private var searchField:some View {
        HStack(spacing:8){
            Image(systemName:"magnifyingglass").font(.system(size:13)).foregroundStyle(.tertiary)
            TextField("Cerca",text:$search).textFieldStyle(.plain).font(.system(size:13)).focused($searchFocused)
                .onSubmit{if let app=results.first {model.launch(app)}}.accessibilityLabel("Cerca app Windows")
            if !search.isEmpty {
                Button{search=""}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.tertiary)}.buttonStyle(.plain).accessibilityLabel("Cancella ricerca")
            }
        }.padding(.horizontal,12).padding(.vertical,10)
            .background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:11))
            .overlay(RoundedRectangle(cornerRadius:11).strokeBorder(searchFocused ? Color.indigo.opacity(0.3):.clear,lineWidth:1))
    }
    private var displays:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20){
                ForEach(Array(model.launcherDisplays.enumerated()),id:\.offset){index,display in
                    Button(action:model.showWindows){
                        HStack(spacing:20){
                            Image(systemName:"display").font(.system(size:34,weight:.ultraLight)).foregroundStyle(.indigo).frame(width:70,height:65)
                            VStack(alignment:.leading,spacing:6){
                                Text(index == 0 ? "Windows":"Schermo \(index+1)").font(.system(size:16,weight:.semibold))
                                if let width=display["width"] as? Int,let height=display["height"] as? Int {Text("\(width) × \(height)").font(.system(size:12)).foregroundStyle(.secondary)}
                            }
                            Spacer()
                            Image(systemName:"arrow.up.right").foregroundStyle(.tertiary)
                        }.padding(20).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:18))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal,32).padding(.bottom,32)
        }
    }
}

@MainActor
private struct LibraryAppTile:View {
    let app:WindowsApplication
    let icon:NSImage?
    let opening:Bool
    let active:Bool
    let enabled:Bool
    let action:()->Void
    @State private var hovered=false
    var body:some View {
        Button(action:action){
            VStack(spacing:12){
                ZStack(alignment:.bottomTrailing){
                    Group {
                        if let icon {Image(nsImage:icon).resizable().interpolation(.high).scaledToFit()}
                        else {RoundedRectangle(cornerRadius:16).fill(Color.primary.opacity(0.04)).overlay(Image(systemName:"app").font(.system(size:28,weight:.ultraLight)).foregroundStyle(.tertiary))}
                    }.frame(width:64,height:64)
                    if opening {ProgressView().controlSize(.small).padding(3).background(.regularMaterial,in:Circle()).offset(x:5,y:5)}
                    else if active {Circle().fill(.green).frame(width:7,height:7).overlay(Circle().stroke(Color(nsColor:.windowBackgroundColor),lineWidth:2)).offset(x:2,y:2)}
                }
                Text(app.name).font(.system(size:12,weight:.medium)).lineLimit(2).multilineTextAlignment(.center).frame(height:32,alignment:.top).frame(maxWidth:.infinity)
            }.padding(.horizontal,10).padding(.top,15).padding(.bottom,8)
                .background(hovered ? Color.primary.opacity(0.045):.clear,in:RoundedRectangle(cornerRadius:16))
                .contentShape(RoundedRectangle(cornerRadius:16))
                .foregroundStyle(.primary)
        }.buttonStyle(.plain).disabled(!enabled || opening).opacity(enabled ? 1:0.55)
            .onHover{hovered=$0}.accessibilityLabel(app.name)
    }
}
