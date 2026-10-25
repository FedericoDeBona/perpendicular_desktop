# Implementazione attuale

Questa pagina descrive la base desktop scelta il 25 ottobre 2026. Identità della VM, pacchetto privato, hash qualificati e checkpoint conservato sono nel [piano operativo](RESTART_PLAN.md). Le vecchie implementazioni WARP/RDP, le prove delle singole finestre e le ricette superate sono nella [cronologia](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/docs/IMPLEMENTATION.md); non sono istruzioni per il sistema attuale.

## Componenti e percorso del desktop

Swift 6, AppKit e Metal gestiscono finestra Mac, input e presentazione. `VirtualMachine.swift` gestisce QEMU/HVF, QMP e la sessione della VM; `RuntimeStore.swift` conserva una copia autonoma e verificata dei binari in `Runtimes/<hash>/` nella cartella della macchina. La pulizia dei prodotti di build non deve rimuovere il runtime dei processi in uso.

Il guest Rust ARM64 espone controllo, stato del display e comandi nella sessione Windows. Il pacchetto privato abilita `PerpendicularDesktopOnly`: apre direttamente «Apri Windows», senza catalogo o catture individuali obbligatori. Il worker installato e il relativo sorgente privato sono identificati nel piano; il servizio ordinario del clone è Manual/Stopped per evitare un secondo worker.

`DesktopConnection.swift` usa il socket RFB privato per input e riconfigurazione del monitor. Quando Native3D produce una superficie valida, `NativeDisplay.swift` importa la memoria condivisa e sospende le richieste di pixel RFB. Il presenter copia la superficie in una texture Metal propria e conferma il frame dopo il completamento GPU. Ridisegno e resize del contenitore riusano la texture locale. Il percorso comprende una copia GPU; non è una promessa di zero-copy.

Il [trasporto C](../macos/NativeTransport/README.md) verifica produttore, sessione, epoch, identità, dimensioni e completamento. L’ACK esatto autorizza il riuso soltanto dopo la fine delle letture Metal. Una disconnessione non rende riutilizzabile memoria ancora in uso. Il protocollo immagini host e il protocollo guest sono contratti distinti.

## Driver, runtime e monitor

Il driver ufficiale ARM64 v0.4 è fissato in [guest/graphics-driver.json](../guest/graphics-driver.json), inclusi hash degli undici file, renderer `cf5af71359b224a9a482e9b5a67f8160497dc951` e protocollo `f510a6e41ea89a6d626de4da9d9b02978a770e37`, Wire2. Driver, UMD/helper e runtime devono rimanere compatibili; il solo numero Wire2 non qualifica una coppia arbitraria.

Il sistema di sviluppo usa VioGpu3D ufficiale, Secure Boot attivo e TESTSIGNING disattivato. Le candidate kernel/UMD auto-firmate sono ritirate; non servono al resize corrente. Il runtime privato conserva QEMU, renderer/server e backend qualificati, con un solo monitor virtuale. [Driver](../graphics/driver/README.md), [renderer](../graphics/renderer/README.md), [backend](../graphics/backend/README.md), [metadati monitor](../graphics/monitor/README.md).

Windows deve seguire il raster della vista, mantenendo ferma la cornice Mac scelta dall’utente. La sequenza verificata pubblica il target, attende 1 s, invia `SetDesktopSize 0×0`, attende 1 s e ripubblica il target. Il primo invio aggiorna il modo custom prima dell’invalidazione dei modi monitor. La sola sequenza 0×0→target è risultata insufficiente. Il writer seriale conserva l’intero ciclo; `VirtualMachine` e `App` associano richieste e risposte e leggono/applicano la geometria Windows dopo l’invio finale. Un ACK RFB o il solo ritorno API non confermano la risoluzione. [Dettagli e limiti](../graphics/driver/custom-resolution.md).

`display_info` legge risoluzione, DPI e area di lavoro effettivi; `driver_info` enumera dispositivi e driver tramite SetupAPI senza dipendere dal provider PowerShell PnpDevice. Le code di configurazione display e prova grafica restano separate. I metadati EDID non impongono la scala Windows: DPI e dimensione percepita non sono qualificati in ogni transizione. La corrispondenza delle finestre individuali attraverso `SharedDisplay` resta un percorso distinto, rinviato.

## Build e confezionamento

`scripts/build-guest.sh` compila il guest con Rust, cargo-xwin, CRT statico e target `aarch64-pc-windows-msvc`. `scripts/build-macos.sh` compila Swift 6 e il trasporto C per macOS ARM64 14, include il guest e confeziona `.build/Perpendicular.app` con firma ad hoc. Richiede Xcode command line tools, la toolchain Rust/cargo-xwin e i runtime QEMU/swtpm previsti dal confezionatore.

La build generica usa `~/Library/Application Support/Perpendicular Restart`. L’app privata build-11 usa invece la VM corrente indicata nel piano e la modalità desktop dedicata. Non sostituire il pacchetto verificato o avviare la build generica presumendo che selezioni lo stesso clone. Il guest privato installato ha sorgente/binario conservati in `DesktopFocus-20261024/current-guest-source`; compilare il guest generico non dimostra di aver riprodotto quel binario.

`SKIP_RUNTIME=1 scripts/build-macos.sh` evita il riconfezionamento QEMU/swtpm, richiedendo un bundle già completo. Se `.build/Native3D` esiste, lo script ne copia comunque il contenuto nel pacchetto: non significa congelare ogni componente grafico. Per modificare soltanto il frontend corrente usare la ricetta conservata con build-11, preparando un nuovo pacchetto privato e mantenendo il precedente fino alla verifica pertinente.

Gli adattatori `prepare-native-wire2.py`, `package-native-wire2.py` e i preparatori grafici hanno input privati e pin specifici. Non costituiscono una build universale del runtime attuale. Per il renderer in uso sono conservati sorgenti/ricette host-7; una nuova compilazione richiede verificare gli input realmente disponibili e qualificare il proprio risultato. Non alterare i pin per accettare un’altra coppia.

## Manutenzione della VM corrente

Con il frontend aperto, indicare sempre il socket della VM di sviluppo:

```sh
python3 scripts/control_guest.py --socket "$HOME/Library/Application Support/Perpendicular IVSHMEM Trial/Control/control.sock" status
python3 scripts/control_guest.py --socket "$HOME/Library/Application Support/Perpendicular IVSHMEM Trial/Control/control.sock" display_info
```

Sono disponibili anche `driver_info`, `graphics_info` ed `execute`. Il comando generico senza `--socket` seleziona la VM ordinaria. L’esecuzione usa il token del worker interattivo senza elevazione automatica, un solo comando alla volta, output limitato e timeout; non equivale a una console SYSTEM.

Il socket locale è privato e controlla l’UID del chiamante; il bridge guest usa un token della macchina. Il collegamento non è progettato per esposizione su LAN/Internet o isolamento fra utenti ostili nella stessa VM. Token, credenziali, dischi e artefatti privati non vanno pubblicati.

## Preparazione e aggiornamenti espliciti

`prepare-machine.py --source /percorso/VM --qemu-img /percorso/qemu-img --dry-run` controlla una sorgente senza copiarla. La preparazione effettiva richiede sorgente spenta, destinazione assente, file non aperti e disco senza backing; conserva insieme disco, EFI e TPM e crea identità di macchina nuove. Non rimuove automaticamente agenti o credenziali contenuti nel disco Windows.

`checkpoint-machine.py` prepara un checkpoint offline; non ripristina automaticamente dati. Prima di usarlo verificare la macchina selezionata. Il checkpoint attualmente conservato precede la riattivazione di Secure Boot: il suo ripristino richiede la cautela specificata nel piano.

`bootstrap-guest.py` è ancora vincolato alla VM ordinaria `Perpendicular Restart`, anche in `--dry-run`. Non è il comando per aggiornare il clone attuale. Per una preparazione esplicita della macchina ordinaria, `--graphics-driver-dir PATH --dry-run` verifica i file del manifest e il Native3D in `.build/Perpendicular.app` senza creare o collegare il CD. `install-graphics.cmd` verifica nuovamente hash e catalogo attendibile, poi usa pnputil con normale elevazione; non disattiva protezioni né forza riavvii. La rimozione delle vecchie integrazioni è un’opzione separata, da non riprendere per completismo.

Nessun aggiornamento o cambio di profilo deve perdere documenti o modificare la VM sbagliata. La verifica minima deve riguardare il passaggio cambiato nell’app reale; build e firma, da sole, non qualificano l’uso Windows. Problemi aperti e direzioni rinviate sono nel [registro](KNOWN_ISSUES.md) e nel [piano](RESTART_PLAN.md).
