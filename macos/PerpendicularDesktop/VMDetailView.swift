import AppKit
import SwiftUI

struct VMDetailView: View {
    let vm: VirtualMachine
    var immersive = false
    var toggleFullScreen: () -> Void = { NSApp.keyWindow?.toggleFullScreen(nil) }
    @EnvironmentObject private var library: LibraryModel
    @ViewState<String> private var tab = "display"
    @ViewState<Bool> private var showConfiguration = false
    @ViewState<Bool> private var confirmForceStop = false
    @ViewState<Bool> private var showSnapshotName = false
    @ViewState<String> private var snapshotName = ""
    @ViewState<VMSnapshot?> private var restoreSnapshot: VMSnapshot?
    @ViewState<VMSnapshot?> private var deleteSnapshot: VMSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !immersive {
            HStack(alignment: .center, spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.blue.opacity(0.1)).frame(width: 58, height: 58)
                    Image(systemName: "desktopcomputer").font(.system(size: 29, weight: .light)).foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(vm.name).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1)
                    HStack(spacing: 7) {
                        Circle().fill(library.connectionError == nil ? vm.stateColor : .orange).frame(width: 6, height: 6)
                        Text(library.connectionError == nil ? vm.stateLabel : "Status unavailable")
                        Text("·")
                        Text("Windows 11 ARM")
                    }.font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                lifecycleButtons.disabled(!library.canControl)
                Menu {
                    Button("Configure…", systemImage: "slider.horizontal.3") { showConfiguration = true }.disabled(!vm.isStopped)
                    Button("Clone…", systemImage: "square.on.square") { NotificationCenter.default.post(name: .cloneVirtualMachine, object: nil) }.disabled(!vm.isStopped)
                    if vm.isoPath != nil {
                        Button("Eject Installation Disc", systemImage: "eject") { Task { await library.action(["eject-iso", vm.id], operation: "Ejecting installation disc…") } }
                    }
                    if vm.guestToolsIsoPath != nil {
                        Button("Eject Driver Disc", systemImage: "eject") { Task { await library.action(["eject-guest-tools", vm.id], operation: "Ejecting driver disc…") } }
                    }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vm.directory)]) }
                    if vm.isActive {
                        Divider()
                        Button("Force Stop…", systemImage: "stop.fill", role: .destructive) { confirmForceStop = true }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }.menuStyle(.borderlessButton).fixedSize().disabled(!library.canControl)
            }.padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 24)

            HStack(spacing: 0) {
                HardwarePill(icon: "cpu", value: "\(vm.cpus) cores", label: "Processors")
                HardwarePill(icon: "memorychip", value: vm.memoryLabel, label: "Memory")
                HardwarePill(icon: "internaldrive", value: "\(vm.diskGib) GB", label: "Storage")
                Spacer()
                Button { showConfiguration = true } label: { Label("Configure", systemImage: "slider.horizontal.3") }
                    .disabled(!vm.isStopped || !library.canControl)
                    .help(vm.isStopped ? "Configure virtual machine" : "Shut down this virtual machine to change its configuration")
            }.padding(.horizontal, 30).padding(.bottom, 24)

            HStack {
                Picker("View", selection: $tab) {
                    Text("Display").tag("display")
                    Text("Snapshots").tag("snapshots")
                }.pickerStyle(.segmented).frame(width: 230).labelsHidden()
                Spacer()
                if tab == "display", vm.isActive {
                    Text("Click the display to use your keyboard.").font(.caption).foregroundStyle(.secondary)
                    Button(action: toggleFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help("Enter Full Screen")
                }
            }.padding(.horizontal, 30).padding(.bottom, 14)
            }

            if let error = vm.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 30).padding(.bottom, 14).textSelection(.enabled)
            }

            if tab == "display" || immersive { console }
            else { snapshots }
        }
        .sheet(isPresented: $showConfiguration) { ConfigurationView(vm: vm).environmentObject(library) }
        .confirmationDialog("Force stop “\(vm.name)”?", isPresented: $confirmForceStop, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) { Task { await library.action(["stop", vm.id, "--force"], operation: "Stopping virtual machine…") } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unsaved work inside Windows may be lost. Try Shut Down first whenever possible.") }
        .alert("New Snapshot", isPresented: $showSnapshotName) {
            TextField("Snapshot name", text: $snapshotName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { Task { await library.snapshotAction(["snapshot-create", vm.id, "--name", name], for: vm, operation: "Creating snapshot…") } }
            }.disabled(snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Save the virtual machine’s disk state so you can return to it later.") }
        .confirmationDialog("Restore “\(restoreSnapshot?.name ?? "snapshot")”?", isPresented: Binding(get: { restoreSnapshot != nil }, set: { if !$0 { restoreSnapshot = nil } }), titleVisibility: .visible) {
            Button("Restore Snapshot", role: .destructive) {
                if let snapshot = restoreSnapshot { Task { await library.snapshotAction(["snapshot-restore", vm.id, snapshot.id], for: vm, operation: "Restoring snapshot…") } }
                restoreSnapshot = nil
            }
            Button("Cancel", role: .cancel) { restoreSnapshot = nil }
        } message: { Text("Changes made to the virtual disk after this snapshot will be replaced. This cannot be undone without another snapshot.") }
        .confirmationDialog("Delete “\(deleteSnapshot?.name ?? "snapshot")”?", isPresented: Binding(get: { deleteSnapshot != nil }, set: { if !$0 { deleteSnapshot = nil } }), titleVisibility: .visible) {
            Button("Delete Snapshot", role: .destructive) {
                if let snapshot = deleteSnapshot { Task { await library.snapshotAction(["snapshot-delete", vm.id, snapshot.id], for: vm, operation: "Deleting snapshot…") } }
                deleteSnapshot = nil
            }
            Button("Cancel", role: .cancel) { deleteSnapshot = nil }
        } message: { Text("The saved restore point will be permanently removed.") }
        .task(id: "\(vm.id)-\(tab)") { if tab == "snapshots" { await library.loadSnapshots(for: vm) } }
        .onChange(of: vm.id) { _, _ in tab = "display" }
    }

    @ViewBuilder private var lifecycleButtons: some View {
        switch vm.state {
        case "running":
            Button { Task { await library.action(["pause", vm.id], operation: "Pausing \(vm.name)…") } } label: { Label("Pause", systemImage: "pause.fill") }.disabled(!library.canControl)
            Button { Task { await library.action(["stop", vm.id], operation: "Requesting shutdown…") } } label: { Label("Shut Down", systemImage: "power") }.disabled(!library.canControl)
        case "paused":
            Button { Task { await library.action(["resume", vm.id], operation: "Resuming \(vm.name)…") } } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(!library.canControl)
        case "starting", "stopping":
            ProgressView().controlSize(.small)
        default:
            Button { Task { await library.action(["start", vm.id], operation: "Starting \(vm.name)…") } } label: { Label("Start", systemImage: "play.fill").padding(.horizontal, 7) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!library.canControl)
        }
    }

    private var console: some View {
        let radius: CGFloat = immersive ? 0 : 12
        return ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Color(red: 0.065, green: 0.075, blue: 0.095))
            if vm.isActive {
                VMConsoleView(socketPath: vm.vncSocket, isActive: vm.state == "running" || vm.state == "paused")
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                if vm.state == "paused" {
                    VStack(spacing: 12) {
                        Image(systemName: "pause.circle.fill").font(.system(size: 44))
                        Text("Virtual machine paused").font(.headline)
                        Button("Resume") { Task { await library.action(["resume", vm.id], operation: "Resuming…") } }.buttonStyle(.borderedProminent).disabled(!library.canControl)
                    }.foregroundStyle(.white).padding(26).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "desktopcomputer").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.white.opacity(0.45))
                    Text(library.connectionError != nil ? "Virtual machine status is unavailable." : (vm.state == "crashed" ? "The virtual machine stopped unexpectedly." : "The virtual machine is powered off."))
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                    Text(library.connectionError != nil ? "Reconnect to the engine before starting this virtual machine." : (vm.state == "crashed" ? "Review the error above, then try starting again." : (vm.isoPath != nil ? "Start to install Windows or continue using your virtual machine." : "Start your virtual machine to continue where you left off.")))
                        .font(.callout).foregroundStyle(.white.opacity(0.45))
                    Button { Task { await library.action(["start", vm.id], operation: "Starting \(vm.name)…") } } label: {
                        Label("Start Windows", systemImage: "play.fill").foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 11)
                            .background(Color.blue, in: Capsule()).opacity(library.isBusy ? 0.5 : 1)
                    }.buttonStyle(.plain).padding(.top, 9).disabled(!library.canControl)
                }.padding(30)
            }
        }.overlay(RoundedRectangle(cornerRadius: radius).stroke(.primary.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if immersive {
                    Button(action: toggleFullScreen) { Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left").font(.caption).padding(9) }
                        .buttonStyle(.plain).foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule()).padding(14)
                        .help("Return to the virtual machine library")
                }
            }
            .padding(.horizontal, immersive ? 0 : 30).padding(.bottom, immersive ? 0 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var snapshots: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Restore points for your virtual machine").font(.headline)
                    Text(vm.isStopped ? "Create a snapshot before making changes to Windows." : "Shut down Windows to create or restore a snapshot.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { snapshotName = Date().formatted(date: .abbreviated, time: .shortened); showSnapshotName = true } label: { Label("New Snapshot", systemImage: "plus") }
                    .disabled(!vm.isStopped || !library.canControl)
            }
            if library.snapshotVMID != vm.id {
                Spacer()
                if library.isBusy { ProgressView().frame(maxWidth: .infinity) }
                else {
                    VStack(spacing: 12) {
                        Text("Snapshots haven’t loaded.").foregroundStyle(.secondary)
                        Button("Load Snapshots") { Task { await library.loadSnapshots(for: vm) } }
                    }.frame(maxWidth: .infinity)
                }
                Spacer()
            } else if library.snapshots.isEmpty {
                ContentUnavailableView("No Snapshots Yet", systemImage: "clock.arrow.circlepath", description: Text("Save a restore point to safely return to a previous disk state."))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(library.snapshots) { snapshot in
                            HStack(spacing: 15) {
                                Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.blue).frame(width: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(snapshot.name).font(.headline)
                                    Text(snapshot.dateLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore…") { restoreSnapshot = snapshot }.disabled(!vm.isStopped || !library.canControl)
                                Button { deleteSnapshot = snapshot } label: { Image(systemName: "trash") }.disabled(!vm.isStopped || !library.canControl).help("Delete Snapshot")
                            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06), lineWidth: 1))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(24).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 30).padding(.bottom, 18)
    }
}

private struct HardwarePill: View {
    let icon: String
    let value: String
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(size: 13, weight: .semibold))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minWidth: 125, alignment: .leading).padding(.trailing, 20)
    }
}
