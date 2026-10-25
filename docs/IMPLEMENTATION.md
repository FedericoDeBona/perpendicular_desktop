# Implementazione attuale

Questa pagina descrive la base desktop scelta il 25 ottobre 2026. Identità della VM principale, app installata, hash qualificati e backup conservato sono nel [piano operativo](RESTART_PLAN.md). Le vecchie implementazioni WARP/RDP, le prove delle singole finestre e le ricette superate sono nella [cronologia](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/docs/IMPLEMENTATION.md); non sono istruzioni per il sistema attuale.

## Componenti e percorso del desktop

Swift 6, AppKit e Metal gestiscono finestra Mac, input e presentazione. `VirtualMachine.swift` gestisce QEMU/HVF, QMP e la sessione della VM; `RuntimeStore.swift` conserva una copia autonoma e verificata dei binari in `Runtimes/<hash>/` nella cartella della macchina. La pulizia dei prodotti di build non deve rimuovere il runtime dei processi in uso.

Il guest Rust ARM64 espone controllo, stato del display e comandi nella sessione Windows. L’app principale apre il catalogo unico delle app Windows, con ultime aperte in alto e «Apri Windows» sempre accessibile. Impostazioni sostituisce il pannello processi nella UI Mac: CPU, RAM iniziale, RAM automatica, limite totale, minimo in background e riserva. Il vecchio flag interno `PerpendicularDesktopOnly` conserva ora la politica di resize del desktop, non nasconde più il catalogo. Finestre già aperte ripristinate dietro alla libreria; un’apertura esplicita dal launcher può attivare la propria finestra. Nella IoT principale il servizio PerpendicularRestart è Running e avvia il worker corrispondente ai sorgenti attivi. I vecchi task dei clone non fanno parte di questa installazione.

`DesktopConnection.swift` usa il socket RFB privato per input e riconfigurazione del monitor. Quando Native3D produce una superficie valida, `NativeDisplay.swift` importa la memoria condivisa e sospende le richieste di pixel RFB. Il presenter copia la superficie in una texture Metal propria e conferma il frame dopo il completamento GPU. Ridisegno e resize del contenitore riusano la texture locale. Il percorso comprende una copia GPU; non è una promessa di zero-copy.

Il [trasporto C](../macos/NativeTransport/README.md) verifica produttore, sessione, epoch, identità, dimensioni e completamento. L’ACK esatto autorizza il riuso soltanto dopo la fine delle letture Metal. Una disconnessione non rende riutilizzabile memoria ancora in uso. Il protocollo immagini host e il protocollo guest sono contratti distinti.

## Driver, runtime e monitor

Il driver ufficiale ARM64 v0.4 è fissato in [guest/graphics-driver.json](../guest/graphics-driver.json), inclusi hash degli undici file, renderer `cf5af71359b224a9a482e9b5a67f8160497dc951` e protocollo `f510a6e41ea89a6d626de4da9d9b02978a770e37`, Wire2. Driver, UMD/helper e runtime devono rimanere compatibili; il solo numero Wire2 non qualifica una coppia arbitraria.

Il sistema di sviluppo usa VioGpu3D ufficiale, Secure Boot attivo e TESTSIGNING disattivato. Le candidate kernel/UMD auto-firmate sono ritirate; non servono al resize corrente. Il runtime privato conserva QEMU, renderer/server e backend qualificati, con un solo monitor virtuale. [Driver](../graphics/driver/README.md), [renderer](../graphics/renderer/README.md), [backend](../graphics/backend/README.md), [metadati monitor](../graphics/monitor/README.md).

Windows deve seguire il raster della vista, mantenendo ferma la cornice Mac scelta dall’utente. La sequenza verificata pubblica il target, attende 1 s, invia `SetDesktopSize 0×0`, attende 1 s e ripubblica il target. Il primo invio aggiorna il modo custom prima dell’invalidazione dei modi monitor. La sola sequenza 0×0→target è risultata insufficiente. Il writer seriale conserva l’intero ciclo; `VirtualMachine` e `App` associano richieste e risposte e leggono/applicano la geometria Windows dopo l’invio finale. Un ACK RFB o il solo ritorno API non confermano la risoluzione. [Dettagli e limiti](../graphics/driver/custom-resolution.md).

`display_info` legge risoluzione, DPI e area di lavoro effettivi; `driver_info` enumera dispositivi e driver tramite SetupAPI senza dipendere dal provider PowerShell PnpDevice. Le code di configurazione display e prova grafica restano separate. I metadati EDID non impongono la scala Windows: DPI e dimensione percepita non sono qualificati in ogni transizione. La corrispondenza delle finestre individuali attraverso `SharedDisplay` resta un percorso distinto, non qualificato dalla pulizia.

## Build e confezionamento

`scripts/build-guest.sh` compila il guest con Rust, cargo-xwin, CRT statico e target `aarch64-pc-windows-msvc`. `scripts/build-macos.sh` compila Swift 6 e il trasporto C per macOS ARM64 14, include il guest e confeziona `.build/Perpendicular.app` con firma ad hoc. Richiede Xcode command line tools, la toolchain Rust/cargo-xwin e i runtime QEMU/swtpm previsti dal confezionatore.

La build e l'app installata selezionano per default `~/Library/Application Support/Perpendicular Memory IoT`. Gli override espliciti PERPENDICULAR_MACHINE_DIRECTORY e PerpendicularMachineDirectory nel plist restano disponibili, ma non sono necessari nell'app principale.

Il confezionamento normale usa copy-main-runtime.py con riferimento `/Applications/Perpendicular.app`: verifica firma, manifest RAM, hash dei file grafici e assenza di link esterni, quindi copia il runtime qualificato nella nuova build. PERPENDICULAR_RUNTIME_APP permette un altro riferimento esplicito. Il riferimento originale è conservato in Research/Memory-20261025/build-native; non eliminarlo senza mantenere una base equivalente. package-runtime.py rimane un preparatore upstream esplicito e non preserva automaticamente le modifiche RAM/native.

`SKIP_RUNTIME=1 scripts/build-macos.sh` richiede un bundle già completo. Solo in questa modalità, se `.build/Native3D` esiste, ne copia il contenuto: è una scelta esplicita per prove, non il normale aggiornamento. La nuova build non va eseguita insieme al frontend installato sulla stessa VM.

Gli adattatori `prepare-native-wire2.py`, `package-native-wire2.py` e i preparatori grafici hanno input privati e pin specifici. Non costituiscono una build universale del runtime attuale. Per il renderer in uso sono conservati sorgenti/ricette host-7; una nuova compilazione richiede verificare gli input realmente disponibili e qualificare il proprio risultato. Non alterare i pin per accettare un’altra coppia.

## Manutenzione della VM corrente

Con il frontend principale aperto, i comandi selezionano la IoT per default:

```sh
python3 scripts/control_guest.py status
python3 scripts/control_guest.py display_info
```

Sono disponibili anche `driver_info`, `graphics_info` ed `execute`. `--socket` resta un override esplicito; il default è la nuova VM principale. L’esecuzione usa il token del worker interattivo senza elevazione automatica, un solo comando alla volta, output limitato e timeout; non equivale a una console SYSTEM.

Il socket locale è privato e controlla l’UID del chiamante; il bridge guest usa un token della macchina. Il collegamento non è progettato per esposizione su LAN/Internet o isolamento fra utenti ostili nella stessa VM. Token, credenziali, dischi e artefatti privati non vanno pubblicati.

## Preparazione e aggiornamenti espliciti

`prepare-machine.py --source /percorso/VM --qemu-img /percorso/qemu-img --dry-run` controlla una sorgente senza copiarla. La preparazione effettiva richiede sorgente spenta, destinazione assente, file non aperti e disco senza backing; conserva insieme disco, EFI e TPM e crea identità di macchina nuove. Non rimuove automaticamente agenti o credenziali contenuti nel disco Windows.

`checkpoint-machine.py` prepara un checkpoint offline; non ripristina automaticamente dati. Prima di usarlo verificare la macchina selezionata. Il backup attualmente conservato è della nuova IoT con protezioni attive e contiene insieme disco, EFI, TPM, configurazione e dati Launcher; il piano indica percorso e verifica.

`bootstrap-guest.py` seleziona la IoT per default; `--machine-directory` permette un'altra destinazione esplicita. `--graphics-driver-dir PATH --dry-run` verifica i pin e il Native3D di `.build/Perpendicular.app` senza creare o collegare media. `--memory-driver-dir` aggiunge i driver RAM firmati. Gli installer verificano nuovamente hash e cataloghi e usano normale elevazione, senza disattivare protezioni o forzare riavvii. La rimozione di vecchie integrazioni rimane un'opzione separata per casi espliciti.

Nessun aggiornamento o cambio di profilo deve perdere documenti o modificare la VM sbagliata. La verifica minima deve riguardare il passaggio cambiato nell’app reale; build e firma, da sole, non qualificano l’uso Windows. Problemi aperti e direzioni rinviate sono nel [registro](KNOWN_ISSUES.md) e nel [piano](RESTART_PLAN.md).


## Libreria, icone e finestre integrate

`LauncherLibrary.swift` conserva catalogo, preferiti e conteggio/data delle aperture accettate nella cartella `Launcher/` della singola VM. La vista iniziale propone app essenziali e usate, con precedenza ai preferiti; “Recenti” ordina per ultima apertura, ricerca e “Tutte le app” mantengono disponibile il catalogo completo. Non vengono enumerate app native del Mac. I dati di utilizzo rimangono locali.

Il guest richiede alla Shell icone ICONONLY a 256×256, originali e senza anteprime di documenti. Il Mac verifica PNG, dimensioni, limite 512 KiB e SHA256 prima di usare o salvare l’immagine. Cache `Launcher/icons-256`, indice con hash e revisione: una riapertura o un aggiornamento del catalogo invariato non richiedono nuove icone. Quando il catalogo fornisce una revisione diversa dell’icona, viene invalidato il solo elemento, senza svuotare tutto. I file sono privati e non appartengono al repository.

Esplora file ha un target namespace `::{…}`: non è un drive mancante. Il filtro per file inesistenti ora richiede una lettera prima di `:`. Esplora file ed Edge che riusano un processo esistente vengono riconosciuti per percorso eseguibile completo e classe ammessa, oltre ai controlli utente/sessione già presenti; non dal titolo. Progman, WorkerW e taskbar dello stesso Explorer non vengono integrati come finestre dell’app.

`NativeWindowFrames.swift`, ricevitore C e `guest/src/windows/gpu.rs` riprendono il protocollo GPU del worker che era già installato. L’endpoint privato è associato a directory e UUID della VM, con verifica del QEMU e del vecchio proprietario prima del riuso. Sul canale frame viaggiano metadati e ACK; la copia GPU Mac precede l’ACK. Sono richiesti renderer/worker corrispondenti, senza fallback pixel TCP o WARP. IVSHMEM non è ripristinato.

Un frame accettato, metadati della stessa misura e completamento Metal possono arrivare in ordini diversi. La transizione iniziale li riconcilia senza attendere un secondo frame di una finestra statica. Il solo timeout dell’attesa non invalida l’ID già richiesto; errori effettivi, geometrie in corso e immagini respinte mantengono i propri blocchi. Questa correzione non risolve contenuti WGC incompleti o tutte le catture ferme.

Il pannello Schermi usa il risultato effettivo di display_info. La base corrente espone una sola uscita: N+1 richiede ancora un driver/runtime compatibile con più uscite. Le prove negative e il prossimo passo sono in WIN-003; non sono state cambiate protezioni o simulate uscite per rendere visibile un controllo.


## RAM dinamica opzionale

Il percorso [RAM](../memory/README.md) combina virtio-mem e balloon con backing
HVF esplicitamente qualificato. Il guest espone GlobalMemoryStatusEx; il
frontend distingue richieste, memoria aggiunta/rimossa dal guest e ownership
balloon. Non deduce il successo da QMP e non forza la rimozione di blocchi in
uso. La politica mantiene una riserva, riduce gradualmente in background ed
espande alla riapertura o sotto pressione guest, senza sospendere la VM.

La configurazione dynamicMemory è opzionale nel codice ed è abilitata nella VM principale.
Native3D richiede il manifest hvf_dynamic_memory_version1 e la mappa PCI
corrispondente; un runtime precedente viene rifiutato. L’app principale
seleziona la cartella IoT per default, senza override nel plist. Installer e media guest controllano i pin dei due driver ARM64
Microsoft-signed in memory-drivers.json. Stato delle qualifiche e tentativi
falliti sono in SYS-003 e VERIFICATION; la promozione nell’app ordinaria è
registrata separatamente dalle prime prove private.

## Impostazioni VM dal launcher0.2.1

MachineSettings.swift valida le risorse e salva soltanto i parametri modificabili in settings-next-start.json privato, associato all’UUID della VM. machine.json non viene cambiato dal salvataggio a Windows acceso. Prima di avviare una VM confermata spenta, applyingPendingSettings fonde i soli campi CPU/RAM nella configurazione corrente preservando campi sconosciuti, identità e stato privato, ricarica il controller e rimuove il file in attesa. Lo stato non verificabile non autorizza l’applicazione. Anche «Apri Windows» passa da questo percorso; un semplice nuovo collegamento al frontend mantiene la configurazione effettivamente in uso. Controller RAM e callback vengono riassociati dopo la ricarica.

La UI mostra valori salvati e configurazione corrente separatamente, più RAM assegnata/disponibile, hotplug e balloon letti dal controller. Il pannello accetta1024 MB iniziali, ma l’avvio Windows con1 GB resta la prova futura dell’utente. Controlli di persistenza e applicazione su fixture riusciti; catalogo installato osservato; verifica interattiva del pannello limitata dall’errore CUA. [Diario](VERIFICATION.md#25-ottobre--catalogo-unico-e-impostazioni-cpuram).
