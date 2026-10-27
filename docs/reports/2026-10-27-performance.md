# Prestazioni CPU, RAM, disco e pipeline grafica — 27 ottobre 2026

La0.2.19 riduce il lavoro periodico del servizio Windows e del lettore desktop Mac. È installata nella main locale93be6687, con lo stesso processo QEMU26233 e senza riavviare Windows. L’analisi RAM/disco non giustifica cambi di configurazione in questo campione. Il desktop nero già presente limita la qualifica grafica: meno polling non significa immagini corrette o minore latenza complessiva.

## Risultati e interventi

Mac Apple M4,24GiB; Windows ARM64,4vCPU, RAM iniziale2048MiB/massima4096MiB. Misure CPU in percentuale di **un core**, non normalizzate sulle4vCPU. Campioni brevi, sequenziali, senza distribuzione statistica o stima di consumo batteria.

| Perimetro | Prima | Dopo | Conclusione pertinente |
| --- | ---: | ---: | --- |
| CPU del worker Windows, nessuna finestra Mac | 3,423% | 0,307% | Riduzione nel campione di circa15s; niente scansioni delle finestre estranee quando non ci sono finestre/lanci Seamless. |
| CPU QEMU nello stesso confronto background | 22,669% | 17,070% | Miglioramento osservato, ma RAM effettiva e storia del worker differiscono; non attribuirlo tutto alla modifica. |
| CPU frontend, desktop1920×1280 senza immagini native nuove | 2,657% | 1,529% | Meno lavoro del lettore nel medesimo guasto grafico. Non è una misura di desktop sano. |
| Risvegli interrupt frontend nello stesso caso | 412,800/s | 14,871/s | Contatore per processo, non energia né numero fisico di risvegli dell’intero Mac. |

La prima baseline background comprende un breve controllo locale del lettore su un altro processo; non è un esperimento di laboratorio isolato. Un secondo campione del **vecchio** servizio dopo il tentativo d’installazione fallito rileva3,084% worker/22,557% QEMU. Il confronto corretto usa l’hash del servizio realmente avviato, non l’esistenza di un nuovo file nella build.

Il worker prima attendeva10ms, osservando le finestre circa ogni75–80ms. Ora attende fino alla prossima osservazione:75ms con finestre o lanci,500ms senza. L’arrivo di un comando interrompe immediatamente l’attesa. Senza finestre/lanci non legge i dettagli di tutte le finestre Windows; senza sessioni applicative evita anche lo snapshot processi. Restano identità esatte e regole di adozione.

Il lettore desktop Mac prima eseguiva un controllo ogni5ms. Ora riceve notifiche di socket e readiness; osserva la scrivibilità soltanto per handshake/ACK e usa un watchdog250ms solo durante un’attesa con scadenza. Un controllo mirato con NDT e Metal reali verifica readiness ritardata, ACK esatto,600ms statici senza polling e disconnessione. Nell’app installata il lettore registra una sola attivazione nel caso fermo; nessun frame nativo è prodotto dal motore guasto. VSync, drawable, copie e regole di rilascio non sono stati cambiati.

Il percorso Seamless finale funziona per la console: launcher→Command Prompt→`echo PERP-PERF-0219`→risultato visibile→`exit`→ritorno al launcher. Durante8s con questa finestra/cursore, worker6,149% e QEMU24,503%: **il costo delle finestre attive resta aperto**. Non è la stessa scena del confronto background e non prova una regressione o un beneficio rispetto a una versione precedente.

## RAM

Il controller esistente restituisce RAM con hot-unplug parziale e balloon; non è stato modificato. Nei rilievi background: RAM effettiva3328–3904MiB, blocchi hotplug ancora presenti e balloon fino704MiB; con console in primo piano ritorna4096MiB, guest4077MiB e1330MiB disponibili. Sono letture del controller, non una nuova prova d’integrità della memoria4→2→4GiB.

QEMU mostra circa5980–6403MiB di footprint nei campioni, molto più del suo residente. `vmmap` conferma regioni condivise e compresse: al rilievo circa4,5GiB di indirizzi shared,1,7GiB swapped in quella categoria, totale writable swapped circa2GiB. La dimensione virtuale non equivale a RAM fisica; footprint, residente e memoria disponibile Windows misurano cose diverse. Non sommare i footprint di QEMU e renderer per attribuire tutta la memoria condivisa o dedurre un leak da questi snapshot.

Nessuna riduzione forzata del massimo/minimo o modifica del backing: senza evidenza di un vantaggio potrebbe aumentare il paging. TODO-012 conserva la qualifica protetta precedente; l’attribuzione dell’eccesso di footprint e dei blocchi pinned rimane da approfondire separatamente.

## Disco e I/O

Percorso effettivo: filesystem Windows→NVMe virtuale→QEMU→qcow2→file/APFS→storage Mac. Nessun passthrough del disco fisico, nessun benchmark sull’immagine viva, nessuna cache fredda artificiale o modifica di flush/durabilità.

Una sola operazione controllata crea un file temporaneo nuovo di6912byte, scrive, richiede `FileStream.Flush(true)`, chiude, rilegge e confronta SHA256, quindi rimuove soltanto quel file. Esito integro. Tempi guest: scrittura5,413ms, flush3,118ms, rilettura calda12,795ms. Includono API/.NET e scheduling; non sono latenze del solo SSD né tempi di salvataggio UI di Notepad.

Nell’intera finestra2,559s, inclusi avvio PowerShell e attività globale VM, QMP conta88letture/1.677.824byte e14scritture/86.016byte; medie QMP0,202ms e0,074ms, zero errori conteggiati. Non attribuire tutte queste operazioni al file. In un precedente campione fermo:3letture/73.728byte e6scritture/61.440byte, medie0,507/0,264ms.

`query-blockstats` va letto sul **BlockBackend** NVMe: la variante `query-nodes=true` restituiva zeri pur con I/O reale. Anche `flush_operations=0` non prova assenza di flush: il percorso NVMe nei sorgenti locali chiama `blk_aio_flush` senza il corrispondente avvio dell’accounting flush usato per quei contatori. `Flush(true)` riuscito non costituisce una prova di resistenza a perdita improvvisa di alimentazione. Durate per richiesta, code APFS e hard fault per processo restano non osservati.

Questo caso non sostiene una modifica del disco come soluzione alla lentezza grafica. La misura circoscritta è completata; attribuzione dell’apertura app e del paging rimane TODO-005/PERF-001.

## Pipeline grafica osservata

Console1838×1020:73header WGC,73copie e73comandi presenter completati senza errore;38presentazioni con timestamp positivo e35con timestamp zero. Tutti gli zeri restano nel conteggio. Inclusi i primi3frame con readback di riferimento; il resto usa il percorso GPU. Non è una distribuzione di tempi di apertura o una misura input→luce del display.

| Tratto | N | Mediana | Massimo |
| --- | ---: | ---: | ---: |
| Attesa query guest, inclusi polling/scheduling | 73 | 2,703ms | 16,003ms |
| Copia GPU host della superficie WGC | 73 | 0,398ms | 6,960ms |
| Callback copia→consegna main | 73 | 0,072ms | 6,204ms |
| Command buffer GPU presenter | 73 | 0,203ms | 3,047ms |
| Header host→presentazione con timestamp positivo | 38 | 25,187ms | 45,217ms |

Non sommare mediane o escludere retroattivamente i35zeri. Una misura piccola della copia non risolve i difetti Wait/Signal, contenuto o recupero. L’outlier UI32ms storico non è riprodotto né dimostrato corretto.

Nell’intervallo di8s delimitato da due calibrazioni QPC/host:16header,11presentazioni positive/5zero. Semilarghezza RTT delle calibrazioni1,112 e3,278ms; offset differisce2,197ms, compatibile con la loro incertezza. Con interpolazione fra questi due soli punti, mediana selezione WGC→presentazione33,230ms sugli11positivi. È un’approssimazione correlata di questo intervallo, non precisione submillisecondo, tempo di produzione dell’app o misura dei frame con timestamp zero.

Traccia finale1946eventi, limite temporale360s raggiunto e nessun evento aggiunto oltre quel confine; il conteggio iniziale1864 precedeva gli ultimi poll UI. Costo dichiarato del record precedente: mediana0,034ms/massimo1,162ms; non misura tutto l’overhead dell’osservatore e non autorizza a sottrarlo dalle durate. La traccia è disattivata nel frontend finale riaperto normalmente.

L’API Metal del Mac M4 espone in questa esecuzione soltanto il set `timestamp/GPUTimestamp`, campionabile al confine di stage; draw/dispatch/blit samplingfalse. Non ottenuti contatori di banda/cache/occupancy. [API Apple](https://developer.apple.com/documentation/metal/mtldevice/countersets). Il lettore conserva la regola di chiudere i descriptor osservati soltanto dopo cancellazione delle relative sorgenti. [Dispatch Sources](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html).

| Copertura | Esito corrente |
| --- | --- |
| Selezione WGC, copia/import, coda UI, command buffer e presentazione frontend | Misurati nella console, con zeri e incertezza conservati. |
| Desktop nativo→presentazione valida | Bloccato in questa sessione da GFX-004, prima della modifica. |
| Rendering app, DWM/driver, virtqueue e job Neptune/DXMT per superficie | Non separati; mancano eventi correlati per frame negli strumenti attivi. |
| Energia, banda/cache/occupancy hardware, input→photon | Non misurati. Nessuna stima presentata come misura fisica. |

## Difetti e stato consegnato

Il desktop era già nero nella0.2.18. Il log rifiuta resource304 mentre303 resta selezionata; latch `failed=true`,1336pubblicazioni/ACK, occupied0, renderer live18/peak72/pending0. Non è nuova saturazione256 e non è la precedente registrazione EGL duplicata. Nella nota di baseline la cattura si ferma dopo un frame e il dialogo non è utilizzabile: GFX-003/WIN-002 conservati, nessuna velocità dichiarata su immagini incomplete. La sola nota sintetica è stata terminata con identità esatta dopo i tentativi ordinari falliti; altre app conservate. La console finale è invece chiusa ordinariamente.

App e build0.2.19 identiche, frontend096d38e2acf7; servizio Running e guest effettivo a7c5354b36a1 corrispondente al bundle. Aggiornamento indipendente nella sessione interattiva; tentativo SYSTEM precedente fallito e registrato. Task temporaneo rimosso, CD vuoto, stesso QEMU26233, Edge7048 preesistente conservato,3mapping e0apply. Secure Boottrue, Code Integrity enabled/options49153, TestSigningfalse. Nessun nuovo clone o riavvio Windows. Frontend finale normale, zero finestre di prova e nessun errore GPU residuo nel frontend; questo non ripristina il desktop nativo già guasto.

**Completati:** riduzione del lavoro periodico nel perimetro misurato, misura CPU/RAM/I/O, lettore verificato localmente e distribuito, pipeline della console documentata. **Restano aperti:** costo delle app attive, attribuzione RAM/paging e backend grafico, recupero del desktop, affidabilità e latenza generali. Prossimo passo utile: correggere/qualificare il rifiuto della superficie desktop, poi ripetere solo la verifica grafica pertinente su immagini native valide; per CPU attiva distinguere thread di osservazione e cattura prima di un’altra modifica.

[Diario completo di errori e verifiche](../VERIFICATION.md#27-ottobre--prestazioni-cpu-ram-disco-e-lettore-grafico-0219). Evidenze private in `Perpendicular Restart/QA/performance-20261027`; nessun disco, credenziale o artefatto generato pubblicato.

Lo strumento [measure-performance.py](../../scripts/measure-performance.py) esegue osservazioni di5–60s sulla VM dell’app installata, verifica UUID/PID e salva un nuovo JSON privato fuori Git. Non genera carico o cambia impostazioni; i nodi QMP non vanno sommati. `--directory` seleziona esplicitamente un’altra directory macchina, `--output` richiede un file nuovo con cartella già esistente. Il controllo [NativeDisplayChecks.swift](../../tests/NativeDisplayChecks.swift) si compila con NativeDisplay.swift, bridge.h e l’oggetto native-transport prodotto dalla build Mac; non avvia Windows e non sostituisce la prova nella main.
