import SwiftUI

@MainActor
struct NetworkSettingsPanel:View {
    @ObservedObject var network:NetworkSettings
    @State private var address=""
    @State private var inputError:String?
    private func card<Content:View>(@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:14,content:content).padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(Color.primary.opacity(0.06)))
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            card {
                Label("VPN Windows sul Mac",systemImage:"network").font(.system(size:14,weight:.medium))
                Text("Usa dal Mac gli indirizzi raggiungibili dalla VPN di Windows. Windows deve restare acceso e la sua VPN collegata.")
                    .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Divider()
                HStack {
                    if network.busy {ProgressView().controlSize(.small)}
                    Text(network.title).font(.system(size:13,weight:.medium)).accessibilityIdentifier("network-status")
                    Spacer()
                    Button("Verifica"){network.refresh()}.disabled(network.busy || network.installationPending || !network.connected)
                }
                if !network.detail.isEmpty {Text(network.detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                if network.installed {
                    Button("Riprendi inoltro"){network.activate()}.disabled(network.busy || network.installationPending || !network.connected)
                    Toggle("Abilita inoltro",isOn:Binding(get:{network.enabled},set:network.setEnabled))
                        .toggleStyle(.switch).controlSize(.small).disabled(network.busy || !network.connected)
                        .accessibilityIdentifier("network-enabled")
                    Text("L'inoltro riprende automaticamente quando Windows si ricollega. La connessione VPN in Windows resta sotto il tuo controllo.")
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Button(network.installationPending ? "Completa installazione":network.installed ? "Installa o ripara componenti":"Installa e attiva") {network.install()}
                    .disabled(network.busy || !network.connected || network.addresses.isEmpty)
                    .accessibilityIdentifier("network-install")
                if network.installationPending {
                    Button("Annulla installazione"){network.cancelInstallation()}.disabled(network.busy || !network.connected)
                }
                if !network.connected {Text("Accendi Windows per installare o modificare il collegamento.").font(.system(size:12)).foregroundStyle(.secondary)}
            }
            card {
                Text("Indirizzi da inoltrare").font(.system(size:13,weight:.medium))
                Text("Solo gli indirizzi elencati passano attraverso Windows. La connessione Internet del Mac resta quella normale.")
                    .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if network.addresses.isEmpty {Text("Aggiungi il primo indirizzo.").font(.system(size:12)).foregroundStyle(.secondary)}
                ForEach(network.addresses,id:\.self){value in
                    HStack {
                        Text(value).font(.system(size:13,design:.monospaced)).textSelection(.enabled)
                        Spacer()
                        Button{network.remove(value)}label:{Image(systemName:"minus.circle")}
                            .buttonStyle(.borderless).accessibilityLabel("Rimuovi "+value).disabled(network.busy || network.installationPending)
                    }
                }
                HStack {
                    TextField("192.168.10.111",text:$address).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Indirizzo da inoltrare").accessibilityIdentifier("network-address")
                        .onSubmit(add)
                    Button("Aggiungi",action:add).disabled(network.busy || address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.disabled(network.busy || network.installationPending)
                if let inputError {Text(inputError).font(.system(size:12)).foregroundStyle(.orange)}
                Button(network.installed ? "Applica indirizzi":"Salva indirizzi") {inputError=nil;network.applyAddresses()}
                    .disabled(network.busy || network.installationPending || !network.dirty || network.addresses.isEmpty || (network.installed && !network.connected))
                    .accessibilityIdentifier("network-apply")
            }
            if let error=network.error {Text(error).font(.system(size:12)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)}
        }.onAppear{network.observe()}.onDisappear{network.stopObserving()}
    }
    private func add(){
        do{try network.add(address);address="";inputError=nil}
        catch{inputError=error.localizedDescription}
    }
}
