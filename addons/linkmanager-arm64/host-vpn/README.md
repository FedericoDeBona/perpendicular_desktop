# IP LinkManager disponibili sul Mac

Prima implementazione locale del28ottobre2026: normali socket Mac raggiungono gli IP/porte IPv4 scelti passando per Windows. TCP e UDP verificati sullo stesso indirizzo di un endpoint temporaneo Windows, senza proxy configurato nell'app Mac. La configurazione lasciata attiva riguarda **192.168.10.111/32, 192.168.20.112/32 e 192.168.27.100/32**. Successivamente l'utente conferma accesso remoto da VM/Mac e reconnect; GET192.168.20.112 restituisce HTTP302/199byte da entrambi. Singola risposta HTTP, senza qualifica della pagina/app completa. Qualità su192.168.10.111:5000 e resetrelay ancora da isolare (ADD-004).

## Percorso effettivo

Mac utun88 → relay cifrato loopback10884 → forwarding QEMU sulla NIC esistente → sing-box ARM64 Windows → socket vincolati a LinkManager Adapter → dispositivo. Shadowsocks2022/AES256-GCM con chiave casuale privata: nessuna password dell'utente richiesta o conservata dal relay. Non richiede altre NIC Windows, forwarding/NAT Windows o reboot.

Il Mac instrada soltanto gli IPv4 /32 scelti. DNS e route predefinita non cambiano. Il server ammette soltanto gli stessi IP e rifiuta il resto; uscita vincolata alla NIC LinkManager, senza alternativa sulla NIC Internet. La chiave e i due firewall Windows limitati a programma/porta/indirizzi restano fuori Git. QEMU espone TCP/UDP soltanto su127.0.0.1:10884; Windows ascolta solo10.0.2.15:10884, firewall con origine10.0.2.2.

Questa è connettività TCP/UDP unicast. ICMP/ping, broadcast, discoveryL2, protocolli che incorporano indirizzi sorgente e connessioni iniziate dal dispositivo verso il Mac non sono qualificati. I nomi DNS della rete remota non sono importati. Le route sono esplicite: non c'è ancora scoperta automatica dei nuovi dispositivi/route LinkManager. Quando si disconnette LinkManager, gli IP scelti restano intercettati dal TUN e non vengono deviati silenziosamente sulla LAN; `stop` ritira il percorso. Un conflitto con la LAN locale sullo stesso IP viene risolto intenzionalmente a favore della route /32 attiva.

## Stato e operazioni

Runtime Mac privato: `~/Library/Application Support/Perpendicular Restart/HostVPN` (0700, configurazione/chiave0600). Runtime Windows protetto: `C:\ProgramData\Perpendicular\HostVPN`, task `PerpendicularHostVPN`, regole `PerpendicularHostVPN-TCP/UDP`. Il servizio LinkManager e il Tray sono componenti distinti e rimangono quelli già installati. Nessun task/daemon di avvio Mac o trigger al boot Windows aggiunto.

Per ora gli indirizzi si impostano dal Terminale: non esiste ancora una schermata nell’app. Il comando `targets` sostituisce l’intero elenco: includere tutti gli IP che si vogliono mantenere. Dalla radice del progetto:

```sh
python3 addons/linkmanager-arm64/host-vpn/host_vpn.py status
python3 addons/linkmanager-arm64/host-vpn/host_vpn.py stop
python3 addons/linkmanager-arm64/host-vpn/host_vpn.py targets 192.168.10.111 192.168.20.112 192.168.27.100
python3 addons/linkmanager-arm64/host-vpn/host_vpn.py start
```

Cambiare gli IP richiede TUN fermo: aggiorna allowlist Windows e configurazione Mac, con controllo prima dell'attivazione e copie private delle configurazioni precedenti. `start` verifica VM/UUID, ripristina i soli forwarding QEMU del relay, avvia il task Windows e chiede l'autorizzazione amministrativa macOS per il TUN. Il piccolo supervisore privilegiato esegue un singolo binario con SHA256 fissato; il socket privato dell'utente consente l'arresto. Non installa helper privilegiati permanenti. `stop` chiude TUN, ferma il relay e ritira i due forwarding QEMU; le regole firewall e i file restano per il successivo avvio.

**Verifiche distinte:** supervisore QA→stop→routeTUN ritirate e successivo avvio finale riusciti; riconoscimento dei forwarding già esistenti e task start idempotente verificati. Successivamente eseguito realmente il ciclo completo stop→targets a due IP→start per aggiungere 192.168.27.100, con serializzazione PowerShell corretta e conferma delle allowlist e delle due route attive. Parser/test della logica di scoping PASS. Reconnect LinkManager successivamente verificato con la v4 nella main; reboot, autoavvio e rimozione completa non qualificati. Il terzoIP è stato attivato con check/backup/riavvio relay e reload mirato del TUN già autorizzato, senza introdurre un comando live generale. status controlla soltanto configurazione/route.

## Preparazione su un'altra macchina

Richiede Python3.9+, clang/SDK macOS e le cartelle condivise già disponibili. Non richiede Homebrew, Go o nuovo driver. Gli output devono essere nuovi e fuori dal repository:

```sh
python3 addons/linkmanager-arm64/host-vpn/prepare.py \
  --runtime "$HOME/Library/Application Support/Perpendicular Restart/HostVPN" \
  --delivery "$HOME/Desktop/Perpendicular-VPN-delivery" \
  --machine-uuid UUID_DELLA_VM \
  --target 192.168.10.111
```

Il runtime deve appartenere alla cartella macchina effettiva (il parent contiene machine.json e Control/control.sock). In Windows ARM64, eseguire elevato `install-relay.ps1 -Source <cartella delivery Windows>`; il pacchetto fissa file/architettura attraverso i pin del downloader/installer. Dopo copia e verifica, ritirare i soli file generati della delivery, soprattutto server.json che contiene la chiave privata. Il preparatore completo è codice di riproduzione, non è stato rieseguito sull'installazione finale per evitare sovrascritture o nuove chiavi; download/pin/configurazioni/compilazioni sono i singoli passaggi realmente verificati.

## Dipendenza scelta

[Versione ufficiale sing-box1.14.4](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4): binari ARM64 macOS/Windows byte-identici alle release, SHA256 archivi/binari nel preparatore e pin Mac nel supervisore. Runtime/archivi generati fuori Git. [Sorgenti corrispondenti](https://github.com/SagerNet/sing-box/tree/v1.14.4) e [licenza GPLv3](https://github.com/SagerNet/sing-box/blob/v1.14.4/LICENSE) vanno conservati/forniti secondo le condizioni in caso di distribuzione.

Scelta motivata: TUN e trasporto TCP/UDP già implementati sul sistema effettivo, nessun nuovo kernel driver Windows e nessuna sostituzione di rete QEMU/Samba. [TUN e route_address](https://sing-box.sagernet.org/configuration/inbound/tun/), [Shadowsocks](https://sing-box.sagernet.org/configuration/inbound/shadowsocks/), [bind_interface](https://sing-box.sagernet.org/configuration/shared/dial/). Candidata circoscritta per il primo percorso utilizzabile, non dipendenza adottata automaticamente in tutta Perpendicular.

Evidenze/fallimenti nel [diario principale](../../../docs/VERIFICATION.md#28-ottobre--ip-vpn-sul-mac-primo-percorso-tcpudp); stato e requisito TODO-024, senza duplicare il registro problemi.
