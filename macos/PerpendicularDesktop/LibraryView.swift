import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    @ViewState<Bool> private var showCreate = false
    @ViewState<Bool> private var showImport = false
    @ViewState<VirtualMachine?> private var deleteVM: VirtualMachine?
    @ViewState<VirtualMachine?> private var cloneVM: VirtualMachine?
    @StateObject private var presentation: WindowPresentation
    @ViewState<NavigationSplitViewVisibility> private var columns: NavigationSplitViewVisibility = .all

    init(presentation: WindowPresentation? = nil) {
        _presentation = StateObject(wrappedValue: presentation ?? WindowPresentation())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    PerpendicularMark(size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Perpendicular").font(.headline)
                        Text("DESKTOP").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 17).padding(.top, 17).padding(.bottom, 24)
                HStack {
                    Text("VIRTUAL MACHINES").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(library.machines.count)").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.bottom, 8)
                List {
                    ForEach(library.machines) { vm in
                        Button { library.selectedID = vm.id } label: {
                            VMRow(vm: vm)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 6)
                                .background(library.selectedID == vm.id ? Color.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 2, leading: 5, bottom: 2, trailing: 5))
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vm.directory)]) }
                                Button("Clone…") { cloneVM = vm }.disabled(!vm.isStopped || !library.canControl)
                                Divider()
                                Button("Move to Trash…", role: .destructive) { deleteVM = vm }
                                    .disabled(!vm.isStopped || !library.canControl)
                            }
                    }
                }.listStyle(.sidebar)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 9) {
                Button { showCreate = true } label: {
                    Label("New Virtual Machine", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }.buttonStyle(.plain).foregroundStyle(.blue).disabled(library.isBusy)
                Button { showImport = true } label: {
                    Label("Import Existing Disk…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption).disabled(library.isBusy)
                }.padding(16)
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(library.connectionError == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(library.connectionError == nil ? "Apple Silicon" : "Engine unavailable").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if library.isBusy || library.refreshing { ProgressView().controlSize(.mini) }
                }.padding(16)
            }
            .frame(minWidth: 220, idealWidth: 255)
            .navigationSplitViewColumnWidth(min: 220, ideal: 255, max: 320)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let vm = library.selectedVM {
                    VMDetailView(vm: vm, immersive: presentation.isFullScreen, toggleFullScreen: presentation.toggleFullScreen)
                } else if !library.didLoad {
                    ProgressView("Loading your virtual machines…")
                } else {
                    EmptyLibraryView(showCreate: $showCreate, showImport: $showImport)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let connection = library.connectionError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(connection).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Retry") { Task { await library.load() } }.disabled(library.isBusy)
                    }.padding(14).background(.bar)
                } else if !library.inventoryWarnings.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(library.inventoryWarnings.joined(separator: "\n")).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Refresh") { Task { await library.refresh() } }.disabled(library.isBusy)
                    }.padding(14).background(.bar)
                } else if library.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(library.operation).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(12).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) { Button { NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) } label: { Image(systemName: "sidebar.left") }.help("Toggle Sidebar") }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New Virtual Machine…") { showCreate = true }
                        Button("Import Existing Disk…") { showImport = true }
                    } label: { Label("Add Virtual Machine", systemImage: "plus") }.disabled(library.isBusy).help("Add Virtual Machine")
                }
            }
        }
        .background(WindowAccessor { presentation.attach($0) }.frame(width: 0, height: 0))
        .toolbar(presentation.isFullScreen ? .hidden : .visible, for: .windowToolbar)
        .onChange(of: presentation.isFullScreen) { _, fullScreen in columns = fullScreen ? .detailOnly : .all }
        .sheet(isPresented: $showCreate) { CreateVMView().environmentObject(library) }
        .sheet(isPresented: $showImport) { ImportDiskView().environmentObject(library) }
        .sheet(item: $cloneVM) { vm in CloneVMView(vm: vm).environmentObject(library) }
        .onReceive(NotificationCenter.default.publisher(for: .createVirtualMachine)) { _ in showCreate = true }
        .onReceive(NotificationCenter.default.publisher(for: .importVirtualDisk)) { _ in showImport = true }
        .onReceive(NotificationCenter.default.publisher(for: .cloneVirtualMachine)) { _ in if let vm = library.selectedVM, vm.isStopped { cloneVM = vm } }
        .alert(library.errorMessage != nil ? "Couldn’t Complete the Action" : "Virtual Machine Added", isPresented: Binding(
            get: { library.errorMessage != nil || (library.noticeMessage != nil && !showCreate && !showImport && cloneVM == nil) },
            set: { if !$0 { library.errorMessage = nil; library.noticeMessage = nil } }
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil; library.noticeMessage = nil }
        } message: { Text(library.errorMessage ?? library.noticeMessage ?? "") }
        .confirmationDialog("Move “\(deleteVM?.name ?? "virtual machine")” to Trash?", isPresented: Binding(get: { deleteVM != nil }, set: { if !$0 { deleteVM = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let vm = deleteVM { Task { await library.action(["delete", vm.id], operation: "Moving virtual machine to Trash…") } }
                deleteVM = nil
            }
            Button("Cancel", role: .cancel) { deleteVM = nil }
        } message: { Text("The virtual machine and its disk will move to Perpendicular’s recoverable Trash. This does not affect other virtual machines.") }
    }
}

private struct VMRow: View {
    let vm: VirtualMachine
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "desktopcomputer").font(.system(size: 24)).foregroundStyle(.blue)
                .frame(width: 36, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(vm.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(library.connectionError == nil ? vm.stateColor : .orange).frame(width: 5, height: 5)
                    Text(library.connectionError == nil ? vm.stateLabel : "Status unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    @Binding var showCreate: Bool
    @Binding var showImport: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(.blue.opacity(0.05)).frame(width: 230, height: 230)
                Circle().stroke(.blue.opacity(0.1), lineWidth: 1).frame(width: 190, height: 190)
                PerpendicularMark(size: 100).shadow(color: .blue.opacity(0.16), radius: 25, y: 12)
            }
            Text("A new home for Windows.").font(.system(size: 32, weight: .semibold, design: .rounded)).padding(.top, 10)
            Text("Create your first Windows 11 ARM virtual machine\nand keep your work right here on your Mac.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 12)
            Button { showCreate = true } label: {
                Label("Create Virtual Machine", systemImage: "plus").padding(.horizontal, 12).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 26).disabled(library.connectionError != nil || library.isBusy)
            Button("Import an Existing Disk…") { showImport = true }.buttonStyle(.link).font(.callout).padding(.top, 13).disabled(library.connectionError != nil || library.isBusy)
            HStack(spacing: 24) {
                Label("Apple Silicon", systemImage: "cpu")
                Label("Windows 11 ARM", systemImage: "desktopcomputer")
                Label("Open source", systemImage: "curlybraces")
            }.font(.caption).foregroundStyle(.tertiary).padding(.top, 25)
            Spacer()
            Text("PERPENDICULAR DESKTOP").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(.tertiary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
