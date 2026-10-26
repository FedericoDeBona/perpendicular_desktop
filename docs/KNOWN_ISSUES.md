# Registro dei problemi

Aggiornato il 26 ottobre 2026. Leggere questo file prima di iniziare o riprendere, poi [RESTART_PLAN.md](RESTART_PLAN.md). Qui sono descritti stato corrente, prossimi passi e criteri di chiusura. La cronologia delle prove e dei fallimenti resta in [VERIFICATION.md](VERIFICATION.md); gli esperimenti ritirati sono indicizzati separatamente in [RETIRED_EXPERIMENTS.md](RETIRED_EXPERIMENTS.md).

Le attività richieste, incluse condivisione degli stessi file Mac e analisi delle prestazioni, sono raccolte nella [TODO obbligatoria](TODO.md), da leggere dopo il piano. La ricognizione documentale del 25 ottobre non cambia gli esiti delle verifiche: nessun nuovo test o difetto chiuso. La TODO rimanda agli ID di questo registro per i problemi già noti.

Comandi Mac e appunti trasversali testo/file sono ora requisiti espliciti in TODO-017/018. Il testo ha un'implementazione e una prova storica circoscritta, mentre file, parità desktop/finestre e qualifica della main restano da completare. Sono attività di prodotto, non nuovi difetti già riprodotti; [ricognizione e limiti](VERIFICATION.md#25-ottobre--requisiti-comandi-mac-e-appunti-trasversali).

## Base corrente e priorità

**Base principale dopo la pulizia del 25 ottobre:** `/Applications/Perpendicular.app`, ora versione0.2.6, collegamento `Perpendicular.app` sul Desktop. App, build e strumenti selezionano per default la IoT0795218c in `~/Library/Application Support/Perpendicular Memory IoT`. Driver grafico e RAM Microsoft-signed, Secure Boot/Code Integrity attivi, TESTSIGNINGfalse confermati dopo l’avvio della0.2.0; la0.2.1 ha conservato la medesima sessione Windows e il runtime. La0.2.2 applica il marchio a VM già spenta, senza avviarla. RAM automatica configurata. [Promozione e pulizia](VERIFICATION.md#25-ottobre--pulizia-definitiva-e-promozione-iot-a-base-principale).

**Catalogo/impostazioni0.2.1:** unica pagina App con recenti in alto e catalogo completo, pannello processi rimosso, impostazioni CPU/RAM salvate per il prossimo avvio. Persistenza e applicazione dopo arresto controllate su fixture con il controller reale; nessun boot della VM a1 GB. Catalogo installato visibile, qualifica interattiva del pannello incompleta per chiusura del canale CUA, senza crash dell’app rilevato. TODO-019 conserva il limite; non è un nuovo difetto di prodotto dimostrato. [Evidenze](VERIFICATION.md#25-ottobre--catalogo-unico-e-impostazioni-cpuram).

**Icona0.2.2:** Carbone e cobalto installato, icona/versione osservate nel Finder e gruppi nativi Base/Stelo presenti in Assets.car; fallback statico incluso. TODO-020 completato; nessun difetto grafico/VM chiuso da questo aggiornamento. [Evidenze](VERIFICATION.md#25-ottobre--icona-carbone-e-cobalto-applicata).

Eliminati su autorizzazione esplicita16 vecchi launcher,12 vecchi dischi/copie (incluso Parallels),10 buffer generati e5 runtime IoT inattivi. Recuperati circa95 GB netti. Preservati disco/EFI/TPM della IoT, backup offline completo SHA256, build qualificata originale build-native, repository, sorgenti e Research/test incerti. Vecchi nomi nelle cartelle residue non indicano VM ancora avviabili. Percorsi e ripristino nel piano.

Il ciclo RAM protetto 4→2→4 GiB con dati conservati resta la qualifica precedente del runtime ora promosso, non una nuova prova estesa durante la pulizia. WGC, N+1 e i problemi grafici non sono risolti dalla promozione. Nel controllo dell'app installata il desktop nativo è visibile, ma Windows rimane2048×1152 e l'app segnala mancata conferma della risoluzione richiesta: GFX-006 resta aperto. Le precedenti prove di resize/fullscreen approvate dall'utente appartengono al clone poi eliminato e restano nel diario.

**Aggiornamento0.2.3:** RAM massima come unico controllo principale, iniziale in Avanzate. Avvio utente1 GB seguito da hotplug fino a4 GB e un nuovo accesso automatico protetto verificati; SYS-004 chiuso, SYS-001 ricomparso. CUA continua a fermarsi sul pannello: DiagnosticReports conferma crash di SkyComputerUseService in Array.remove(at:); TODO-019 mantiene il limite di qualifica UI. [Evidenze](VERIFICATION.md#25-ottobre--ram-semplificata-e-accesso-windows).

**Intervento prestazionale precedente:** correzione UI circoscritta installata/verificata nella0.2.4 (notifiche ripetute evitate e consegna diretta dei frame). Tentativi di ridurre l’attesa di presentazione respinti; presenter precedente conservato. Outlier UI32 ms e attribuzione guest/runtime ancora aperti, nessun beneficio di latenza inventato. [Esito pratico](reports/2026-10-25-graphics-latency-update.md), [verifica](VERIFICATION.md#25-ottobre--tentativi-di-riduzione-latenza-e-ui-024). PERF-001/WIN-004/GFX-007 non chiusi.

**Aggiornamento corrente0.2.5:** percorso N+1 misto protetto installato nella main, con un Mac fisico e due uscite Windows (3D riservato+DOD app). Mapping stabile/DPI app192, testo, drag, resize, dialogo e Cancel verificati nell’app canonica. Desktop3D conservato2048×1152/DPI144; non necessita corrispondenza al Mac. Il precedente tentativo di forzarne il raster fallisce1610, senza chiudere GFX-006 in generale. Tre uscite nel clone erano una prova distinta. Trasferimento fra Mac di scala diversa, cambio monitor, riserva taskbar/Snap e guasti grafici rimangono aperti. [Evidenze0.2.5](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

**Aggiornamento corrente0.2.6:** input per app cloaked implementato e distribuito; qualifica circoscritta su Notepad, dialoghi e navigazione Explorer. Secure Boot/CI conservati, nessuna modalità test. Limiti WGC e separazione delle app a istanza singola ancora aperti. [Evidenze](VERIFICATION.md#26-ottobre--input-per-finestre-cloaked-e-distribuzione-026).

## Come aggiornare il registro

- Aggiornare la voce esistente conservandone l’ID; crearne una soltanto per un difetto distinto.
- Distinguere requisito utente, ipotesi, risultato misurato e distribuzione effettiva. Collegare le prove nel diario senza accumulare qui i vecchi handoff.
- Chiudere solo dopo verifica del criterio indicato. Una riuscita di laboratorio o nel clone non qualifica l’app ordinaria o l’affidabilità generale.
- Conservare fallimenti nel diario e dati privati fuori Git. Non ripetere test senza modifiche pertinenti o nuove evidenze.

## Problemi pertinenti al desktop

### GFX-009 — Desktop nero per backend duplicato e scanout escluso dalla build locale

- **Stato:** corretto e verificato sul secondo Mac/VM93be6687; nessuna nuova qualifica generale del driver. Windows e le due uscite erano attivi, ma Apri Windows mostrava la console RFB inattiva800×600.
- **Cause verificate:** il backend EGL stock sostituiva la registrazione del backend nativo; inoltre un controllo di link fallito e memorizzato aveva lasciato HAVE_VIRGL_RENDERER_NATIVE_SCANOUT disabilitato pur con le funzioni presenti nella libreria. La prima consegna non aveva verificato il desktop dopo l'allineamento.
- **Correzione:** esclusa la registrazione stock dal profilo Darwin nativo, ripristinata la singola unità scanout dopo probe positivo sulle librerie effettive; guardia di configurazione per impedire il ripiego silenzioso. QEMU4ab6275c4d11 distribuito e firmato.
- **Criterio verificato:** desktop reale1920×1280 visibile, nativeActive=true, menu Start aperto dal mouse,86 frame pubblicati/ACK nel campione. WinUI parziale resta GFX-001 e il dialogo WIN-002 non è stato riprovato.
- **Limite distinto:** primo arresto ordinario non completato entro60s; QMP poi chiuso con processo ancora vivo. Uscita forzata solo dopo consenso esplicito, successivi due arresti ordinari riusciti. Non dichiarata risolta l'affidabilità di arresto SYS-001/TODO-009.
- **Evidenze:** [diario](VERIFICATION.md#26-ottobre--ripristino-del-desktop-nativo-sul-secondo-mac).

### PERF-001 — Explorer nel desktop compare prima del contenuto completo

- **Seguito pipeline25 ottobre:** frontend temporaneo sulla VM principale: tratto desktop ingresso→presentazione mediano41,498 ms, GPU copy+draw0,476 ms nel campione1920×1280. Non sono tempi di apertura/produzione Explorer e non spiegano da soli i secondi del rapporto precedente. Nessuna causa o correzione chiusa. [Report pipeline](reports/2026-10-25-graphics-pipeline.md), [verifica](VERIFICATION.md#25-ottobre--pipeline-grafica-con-timestamp-gpu-e-presentazione).

- **Stato:** difetto prestazionale riprodotto nella main0.2.3; analisi consegnata, nessuna ottimizzazione applicata. Percorso desktop Native3D, senza usare finestre integrate/WGC.
- **Verificato:** Home con osservazione leggera: finestra Win32 rilevata1,39 s, primo frame vicino al riferimento completo entro5,41 s. Home con profiler CPU host:3,25/11,06 s. Questo PC, nuovo processo:3,63/9,71 s, poi ulteriore caricamento fino a circa13,20 s. Condizioni diverse, non una distribuzione statistica o un A/B controllato.
- **Diagnosi circoscritta:** UI bianca e poi progressiva; pubblicazioni/ACK continuano. Carico Explorer significativo; swap host effettivo elevato sul Mac8 GiB e QEMU con molto contenuto non residente nel rilievo successivo. Nessuna attribuzione causale esclusiva a RAM, CPU, disco o GFX-007. Timestamp GPU/stadi guest completi non ottenuti.
- **Prossimo passo:** scelta dell’utente dopo il report; raccomandato un confronto con pressione host e RAM effettiva controllate, poi attribuzione CPU/paging guest. Non modificare driver, protezioni o caching per tentativi.
- **Chiusura:** causa del ritardo identificata e intervento verificato sul medesimo percorso con criterio di contenuto visivo completo e condizioni confrontabili; conservare i limiti di osservabilità.
- **Evidenze:** [rapporto dettagliato](reports/2026-10-25-explorer-opening.md), [diario](VERIFICATION.md#25-ottobre--analisi-apertura-explorer-nel-desktop-vm).

### GFX-004 — Risorse grafiche indisponibili e recupero incompleto

- **Rilievo Explorer main0.2.3:** nelle aperture desktop il live sale circa23→33→43 e poi fino a51. Nessun nuovo rifiuto/saturazione nelle finestre di misura; poche aperture e processi/cache diversi non provano un leak o rilascio generale. [Rapporto PERF-001](reports/2026-10-25-explorer-opening.md).

- **Stato:** aperto, causa non isolata. In una sessione desktop il registro delle risorse raggiunge live256, rifiuta nuove registrazioni e il presenter diventa nero. Un reset adattatore recupera il percorso, senza dimostrare una correzione.
- **Verificato:** nel successivo uso di Calcolatrice, Settings/HDR e video le risorse passano da 40 a un picco di 79 e scendono a 37, con pending0/rejected0. La prova precede il ripristino del driver ufficiale; non qualifica durata indefinita né identifica la causa della saturazione. Il diario conserva anche perdita device, timeout e recuperi delle vecchie catture WGC.
- **Prossimo passo:** se il guasto ricompare nel desktop, correlare risorse ancora possedute da guest, renderer e contesti usciti prima di cambiare limiti o aggiungere retry.
- **Chiusura:** guasto identificato e risorse rilasciate, con desktop nuovamente utilizzabile senza spegnere l’intera VM.
- **Evidenze:** [saturazione e recupero](VERIFICATION.md#24-ottobre--ripristino-del-resize-personalizzato-del-desktop), [app reali e rilascio risorse](VERIFICATION.md#25-ottobre--verifica-del-desktop-accelerato-app-reali-e-rilascio-risorse).

### GFX-006 — Risoluzione e DPI errati dopo installazione a caldo

- **Seguito promozione IoT:** desktop nativo visibile2048×1152, richiesta della vista non confermata e avviso nel launcher dopo riapertura. Nessuna modifica alla logica resize o al runtime grafico in questa pulizia; causa non isolata, nessuna regressione causale attribuita ai soli nuovi percorsi. Build qualificata originale conservata. [Diario](VERIFICATION.md#25-ottobre--pulizia-definitiva-e-promozione-iot-a-base-principale).
- **Stato:** aperto per la procedura di aggiornamento e la conferma del modo; recupero dopo avvio completo precedentemente verificato nel clone. L’installazione a caldo può lasciare 1024×768/DPI96 e fallire l’applicazione di un modo pur accettato nella verifica API.
- **Prossimo passo:** prima di distribuire un aggiornamento definire il riavvio necessario e confermare geometria/DPI effettivi prima di riabilitare input e trasformazioni condivise.
- **Chiusura:** aggiornamento e riavvio eventualmente richiesto portano al display concordato; l’app non presenta come applicata una modalità non osservata.
- **Evidenze:** [installazione e recupero](VERIFICATION.md#24-ottobre--gate-pronto-prima-delluso-e-frame-valido-al-resize), [avvio protetto della base corrente](VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

### SYS-001 — Arresto HVF durante riavvio o arresto

- **Nuova ricorrenza:** riavvio per verificare autologon: assertion `(isv)`, hvf.c2184, uscita QEMU28213. Successivo avvio35616 con1 GB iniziale e login automatico riuscito; non è una correzione HVF. [Evidenze](VERIFICATION.md#25-ottobre--ram-semplificata-e-accesso-windows).

- **Seguito launcher:** ricomparsa durante l’arresto regolare del vecchio pacchetto; controllo offline qcow2 con check-errors=0, nessuna riparazione o restore, successivo arresto/avvio riuscito. [Evidenze](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Stato:** aperto; assertion `(isv)` in `hvf_vcpu_exec`/hvf.c2378 osservata anche con KMD ufficiale. Nessuna causa attribuita al resize.
- **Verificato:** ricomparsa durante sostituzione/arresto del 25 ottobre; verifica offline del disco senza errori e successivo avvio con protezioni attive riuscito. Anche arresti ACPI completi riusciti; non sono una soluzione causale.
- **Prossimo passo:** se ricompare, conservare istruzione/MMIO e contesto del medesimo guasto prima di cambiare il gestore HVF.
- **Chiusura:** causa identificata e medesimo passaggio prima difettoso completato con il runtime corretto.
- **Evidenze:** [diario del ripristino protezioni](VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

### SYS-002 — Spazio host esaurito durante le scritture VM

- **Priorità:** su richiesta del25 ottobre rimossa TODO-010 dall'elenco operativo; questa voce conserva l'incidente storico, senza dichiararlo corretto né riproporne automaticamente il lavoro. [Revisione](VERIFICATION.md#25-ottobre--revisione-todo-e-difetto-di-sincronizzazione-gpu).
- **Stato:** spazio recuperato e immagine riparata nel clone; prevenzione nel prodotto ancora aperta.
- **Verificato:** con 103 MiB liberi QEMU termina per `aio failed: No space left on device`. Riparati due cluster non referenziati, nessuna corruzione residua, Windows riavviato con volume Healthy. La pulizia successiva libera 25.051.377.664 byte, con circa 46,4 GB disponibili al controllo del 25 ottobre; questo valore è un rilievo storico, non una misura aggiornata a ogni lettura.
- **Prossimo passo:** prima di distribuire definire controllo e segnalazione dello spazio host per evitare una terminazione cieca durante le scritture.
- **Chiusura:** spazio insufficiente gestito senza perdita dati e con errore utilizzabile nell’app; il recupero manuale non basta.
- **Evidenze:** [incidente e recupero](VERIFICATION.md#24-ottobre--driver-per-risoluzioni-personalizzate-preparazione-e-installazione-nel-clone), [pulizia autorizzata](VERIFICATION.md#25-ottobre--pulizia-delle-vecchie-prove-e-base-corrente).

### SYS-003 — RAM della VM non restituita al Mac a runtime

- **Secondo Mac,26 ottobre:** motore ricostruito e installato sulla VM93be6687, con i driver originali e protezioni attive. Massimo8 GiB preservato, base2 GiB e6 GiB hotplug. Memoria Windows passa da circa2 a8 GiB; poi unplug/balloon effettivi osservati e ritorno completo8 GiB/pendingfalse durante l'uso dell'app. Nessuna nuova prova estesa di integrità o promessa di footprint minimo. [Evidenze locali](VERIFICATION.md#26-ottobre--allineamento-completo-del-motore-sul-secondo-mac).

- **Stato:** corretto e qualificato nella nuova IoT pulita, ora promossa a VM principale dell’app installata0.2.0 con lo stesso runtime Native3D. La prima valutazione negativa non costituiva raggiungimento dell'obiettivo e resta nel diario.
- **Requisito:** VM sempre accesa, restituzione/riassegnazione reale a runtime; Secure Boot attivo, Code Integrity attiva e TESTSIGNING disattivato.
- **Verificato:** installazione nuova dalla ISO IoT ARM64 LTSC 2024 dell'utente, senza Tools Parallels. Balloon ARM64 271 e VioMem ARM64 304 Microsoft-signed Running con protezioni attive. Hotplug +512 MiB osservato esattamente nella memoria Windows; rimozione reale parziale e successiva aggiunta senza reboot. Balloon 4→3 GiB con circa 713 MiB di footprint Mac recuperato, ritorno e nuova allocazione verificata. Controllo continuo su 128 MiB senza variazioni di hash.
- **Integrazione:** controller automatico opzionale: espande alla riapertura o sotto pressione guest, rimuove prima memoria fisica ceduta, usa il balloon per compensare blocchi ancora occupati. Nel pacchetto standard: dopo un carico di 768 MiB, chiusura del desktop con VM accesa porta footprint da 3.772.126.848 a 3.016.431.304 byte (circa 721 MiB); riapertura restituisce 4 GiB e azzera il balloon. Non è una garanzia di consumo minimo fisso.
- **Limiti:** hot-unplug può restare parziale per pagine in uso/pinned; non forzarne la rimozione. Snapshot RAM/balloon ora atomico: corretto un primo conteggio incoerente durante unplug. La prima prova RAMFB non qualificava resize/accelerazione; la successiva verifica Native3D è distinta. WGC escluso dalla richiesta.
- **Native3D:** nel pacchetto finale, 4→2→4 GiB senza reboot; footprint3.862.152.032→3.361.448.704 byte, circa478 MiB recuperati. Rimossi fisicamente1034 MiB hotadded;1014 MiB restano pinned e sono compensati dal balloon. Tutta la capacità ritorna, reusable0/failures0. Probe128 MiB integro per48 letture, anche durante il ritorno; nuova allocazione256 MiB verificata. Desktop1920×1280 nativo, menu Start dopo il ciclo, protezioni confermate. Preservati renderer/server/backend; corrette esclusione EGL Darwin e mappa PCI alta per questo opt-in.
- **Criterio verificato nello sviluppo:** ciclo runtime completo nell'app IoT prevista, contenuto conservato, ritorno al bisogno e protezioni confermati. Promozione nell’app ordinaria eseguita il25 ottobre; la IoT diventa il default e i vecchi dischi sono eliminati per autorizzazione esplicita. Runtime/driver conservati, avvio protetto e controller attivo confermati; nessuna nuova qualifica estesa WGC/resize.
- **Evidenze:** [prima valutazione negativa](VERIFICATION.md#25-ottobre--ballooning-e-hotplug-ram-prima-valutazione-protetta), [IoT pulita e RAM reale](VERIFICATION.md#25-ottobre--iot-pulita-balloon-hotplug-e-controllo-automatico), [promozione ordinaria](VERIFICATION.md#25-ottobre--pulizia-definitiva-e-promozione-iot-a-base-principale).

### SYS-004 — Accesso automatico IoT esaurito

- **Stato:** chiuso sulla main dopo ripristino autorizzato e nuovo avvio reale senza password. Credenziale invariata in LSA, AutoAdminLogon1, nessun contatore né password plaintext; Secure Boot/CI attivi e TestSigningfalse.
- **Evidenza:** setup originale limitato a8 accessi automatici. Sulla main AutoAdminLogon0, AutoLogonCount assente e password Winlogon assente; credenziale originale ancora valida e login riuscito. Esaurimento coerente con il setup/documentazione Microsoft, senza contatore residuo che provi il numero effettivo di accessi. Nessun nesso dimostrato con1 GB RAM.
- **Prossimo passo:** nessun test aggiuntivo; riaprire soltanto su ricorrenza osservata. Script di ripristino in scripts/restore-autologon.ps1, nessuna password negli argomenti.
- **Chiusura:** accesso automatico reale nella main, protezioni boot conservate e nessuna password cambiata o pubblicata.
- **Evidenze:** [semplificazione RAM e accesso](VERIFICATION.md#25-ottobre--ram-semplificata-e-accesso-windows).

### SYS-005 — Aggiornamento del servizio guest interrotto dalla propria chiusura

- **Stato:** aperto per la procedura automatica. Nella main l’installer avviato attraverso il proprio broker si interrompe durante la sostituzione: nuovo file presente ma servizio ancora sul vecchio percorso, capacità displayTopology assente. Non basta il disconnect a provare il successo.
- **Recupero verificato:** attività Windows temporanea nello stesso account interattivo elevato, indipendente dal job del broker, completa l’aggiornamento e si elimina. Nuovo servizio6c9c494886c6 Running, transcript concluso e capacità letta. Nessuna password o modifica dei privilegi persistenti. Questa procedura manuale non è ancora un updater robusto nel prodotto.
- **Prossimo passo / chiusura:** installazione esterna al servizio che attende la sostituzione e conferma versione/capacità dopo riconnessione; conservare rollback e segnalare l’errore senza dichiarare completamento dal solo disconnect. Il setup grafico deve usare l’INF qualificato in DriverStore: quello dal CD fallisce0xe0000217 nel caso osservato.
- **Evidenze:** [distribuzione0.2.5 e tentativi](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025), TODO-009.

### APP-002 — Esplora file assente e finestre riusate non riconosciute

- **Stato:** filtro del catalogo e associazione corretti nel clone del launcher. Esplora file ed Edge presenti fra le app principali e aperti in finestre Mac; distribuzione ordinaria non qualificata.
- **Causa/correzione:** il target namespace `::{…}` di Esplora file veniva scambiato per un drive mancante perché il secondo carattere è `:`. Il controllo ora richiede una lettera di unità. Per i due programmi che riusano processi esistenti, associazione per percorso eseguibile completo e classe della finestra; il solo PID restituito dalla Shell non basta. Desktop/taskbar dello stesso Explorer sono esclusi, anche al ripristino.
- **Chiusura:** catalogo e avvio delle due app verificati nel pacchetto destinato all’utente, senza inglobare il desktop o duplicare le app. I pixel mancanti di Esplora file restano GFX-001.
- **Evidenze:** [prova launcher](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).

## Limite delle acquisizioni automatiche

### GFX-008 — Screenshot fullscreen con fasce bianche e frammenti

- **Stato:** limite delle acquisizioni CUA con causa non isolata; nessun difetto fullscreen visibile confermato dall’utente. Non blocca il resize corrente.
- **Verificato:** Windows e scanout concordano su 2880×1800; le acquisizioni fullscreen risultano frammentate, quelle in finestra complete. L’utente conferma direttamente assenza di bande nere o anomalie percepite. Riaprire il binding CUA può uscire dal fullscreen: un’immagine pulita successiva non prova la soluzione dell’acquisizione.
- **Prossimo passo:** approfondire soltanto se serve una cattura fullscreen affidabile o compare un difetto visibile. Non modificare driver/presenter per il solo screenshot.
- **Chiusura:** acquisizione completa nel passaggio difettoso e causa del solo acquisitore identificata con evidenza indipendente.
- **Evidenze:** [artefatto acquisito](VERIFICATION.md#24-ottobre--seconda-candidata-resize-geometrie-effettive-e-pulizia-autorizzata), [riscontro utente](VERIFICATION.md#24-ottobre--riscontro-utente-fullscreen-senza-anomalie-visibili).

## Finestre individuali, sincronizzazione GPU ed esperimenti ritirati

Queste voci conservano limiti non risolti, senza richiedere di ripristinare codice, dischi o protezioni delle prove eliminate. Il percorso individuale è ripreso dalla nuova richiesta di launcher; i vecchi esperimenti kernel e IVSHMEM restano ritirati. Riprendere una prova tecnica soltanto per una necessità concreta del percorso attivo.

### GFX-001 — Flicker e cifre mancanti nelle catture WGC

- **Stato:** aperto nel percorso individuale, ora ripreso. Nel nuovo launcher Esplora file si apre e presenta immagini aggiornate, ma alcune etichette delle cartelle sono assenti: nuova riproduzione circoscritta, non una correzione del contenuto. Il desktop diretto conserva il precedente riscontro distinto. PNG già ricevuti dal Mac mostravano cifre mancanti prima del disegno Metal; i campioni completi con hash uguali non escludono la compressione nel caso parziale.
- **Prossimo passo, se ripreso:** conservare una riproduzione pertinente e seguire produzione, cattura e lettura della superficie, senza riattivare per deduzione la candidata DWM.
- **Chiusura:** stesso passaggio prima difettoso completo e aggiornato nell’app reale, con componenti identificati e breve verifica di input/resize.
- **Evidenze:** [pixel prima/dopo trasporto](VERIFICATION.md#24-ottobre--confronto-dei-pixel-prima-e-dopo-il-trasporto), [riscontro desktop](VERIFICATION.md#25-ottobre--verifica-del-desktop-accelerato-app-reali-e-rilascio-risorse).

### GFX-002 — Arresti DWM con driver candidato

- **Stato:** esperimento ritirato, causa non risolta. La candidata non è il driver corrente. Arresti in `neptune_umd_arm64.DLL`, payload 05ebb1b2a56b, eccezione c0000409 / RVA1108b8; il fast-fail CRT è identificato, il chiamante no. Non è una diagnosi di buffer overflow.
- **Prossimo passo, se ripreso:** individuare chiamante e contesto prima di altre varianti o attivazioni DWM.
- **Chiusura:** causa isolata e corretta, poi percorso reale con cattura aggiornata e recupero riusciti. I controlli fence non qualificano DWM.
- **Evidenze:** [arresti e recupero](VERIFICATION.md#24-ottobre--confronto-dwm-non-qualificato-fast-fail-e-recupero), [sorgenti ritirati](RETIRED_EXPERIMENTS.md).

### GFX-003 — Cattura ferma dopo cambio compositore

- **Seguito riapertura Notepad locale,26 ottobre:** con la prima candidata solo input/taskbar f5c6ab5a, minimizza→libreria→Notepad riproduce pixel-hash sull'epocaCF8544CC. Riferimento del trasporto ora letto dalla stessa allocazione esportata, immutabile fino all'ACK; seconda lettura WGC conservata separatamente in transportReference. Nella candidata finale bad09cca la stessa sequenza mostra13frame, cloaking attivo e nessun nuovo errore per l'epoca49359717. Sorgente/export uguali nel campione: non dimostra che una mutazione WGC causasse il mismatch precedente. Nessun controllo host/marker/ACK disattivato; GFX-003 resta aperto in generale. [Diario](VERIFICATION.md#26-ottobre--riapertura-notepad-e-cloaking-dopo-input-non-client).

- **Verifica locale dopo il ripristino desktop,26 ottobre:** alla segnalazione di cloaking inattivo, ultima diagnostica pixel-hash della finestra :1 ma nessuna app integrata ancora aperta. Un nuovo Notepad dalla libreria (:2) mostra contenuto sul Mac,10frame presentati e DWM_CLOAKED1 verificato indipendentemente. Nessun riavvio o modifica; il guasto precedente non è risolto e la diagnostica storica non descrive tutte le finestre successive. Task Manager non disponibile nel launcher resta non qualificato. [Evidenza circoscritta](VERIFICATION.md#26-ottobre--verifica-del-cloaking-dopo-il-ripristino-desktop-locale).

- **Allineamento successivo sul secondo Mac:** incluso anche il backend con inizializzazione prima dell'export, assente nella prima consegna. Nella breve prova finale Notepad hardware,44frame e windowGPU vuoto, testo e cloaking utilizzabili. Questo non dimostra risolti tutti i mismatch: il dialogo distinto resta in attesa di presentazione (WIN-002). [Verifica locale](VERIFICATION.md#26-ottobre--allineamento-completo-del-motore-sul-secondo-mac).

- **26 ottobre, secondo Mac:** aggiornamento richiesto sulla VM locale `93be6687`, distinta dalla main dell'altro PC. Notepad principale riceve testo in hardware; nel percorso dialogo/desktop compare `windowGPU.reason=pixel-hash`, seguito da immagini indisponibili e input sospeso. Riaperto soltanto il frontend dopo chiusura della prova generata; nessun reboot o correzione causale. Renderer locale ricostruito dal riferimento Wire2 disponibile con export WGC; non è host-7 dell'altro PC. [Evidenze e limiti](VERIFICATION.md#26-ottobre--pull-rebuild-e-guest-tool-sul-secondo-mac). Voce aperta; nessuna attribuzione automatica del mismatch a GFX-007.

- **Seguito0.2.5:** corretto un guasto concreto della riconnessione: renderer ancora sul vecchio socket WGC e frontend su uno nuovo. Record di avvio autenticato e lock per VM ora conservano il socket effettivo. Stesso documento ripreso nel clone e nella main, senza reboot Windows. Pixel-hash transitorio ricompare nel clone e poi recupera: GFX-003 resta aperto, controlli conservati. [Evidenze](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

- **Seguito multischermo protetto:** nel trasferimento iniziale Notepad al DOD compare `pixel-hash`; la finestra in seguito mostra nuovamente contenuto e input aggiornati. Nessun controllo disattivato, nessuna causa o affidabilità generale del recupero dimostrata. La diagnostica conserva l’ultimo errore e non descrive da sola l’esito di ogni frame successivo. [Evidenze](VERIFICATION.md#25-ottobre--todo-001-alternative-protette-e-associazione-per-dispositivo).

- **Nuova evidenza durante i tentativi di latenza:** alcune riconnessioni dello stesso Notepad producono `windowGPU.reason=pixel-hash`, con sorgente associata al marker ma hash guest/host diversi prima del presenter. Conservati i controlli, nessun ACK di successo del frame non verificato; nessuna causa attribuita automaticamente alle candidate. Chiusura del solo documento temporaneo e nuova apertura consentono la verifica finale nella0.2.4; non è recupero qualificato dello stesso documento e non chiude il problema. [Diario](VERIFICATION.md#25-ottobre--tentativi-di-riduzione-latenza-e-ui-024).

- **Seguito launcher:** la riapertura ha mostrato anche un errore transitorio di disponibilità dell’immagine GPU, recuperato dalla riconnessione; causa non isolata, non confondere con l’attesa del presenter corretta in WIN-002. Conservata la prova negativa. Il pacchetto finale riapre le due finestre con primo frame presentato e gate concluso, senza errore GPU registrato nel tratto; aggiunta diagnostica privata `windowGPU` per un’eventuale ricomparsa, senza fallback o indebolire hash/identità. [Evidenze](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Stato:** aperto nel percorso individuale. Windows contiene 79 mentre la cattura mostra 78; riavviare il worker recupera il contenuto senza riavviare l’app. Recupero automatico non verificato.
- **Prossimo passo, se ripreso:** riconoscere la sessione WGC invalida e ricrearla conservando identità, sequenze e input.
- **Chiusura:** frame aggiornati dopo cambio compositore senza riavvio manuale del worker, duplicati o immagini della vecchia sessione.
- **Evidenze:** [caso e recupero](VERIFICATION.md#24-ottobre--confronto-dwm-non-qualificato-fast-fail-e-recupero). Il diverso blocco del proprietario GPU, corretto nel prototipo poi ritirato, resta distinto nel diario.

### GFX-005 — Desktop nero nella candidata multi_ring

- **Stato:** esperimento ritirato, cattura multi_ring non implementata. Il rifiuto iniziale contiene il guasto e conserva nuovi contesti, ma non rende disponibile lo snapshot nativo.
- **Prossimo passo, se ripreso:** definire cattura compatibile con lo scheduling senza ammettere snapshot non sicuri.
- **Chiusura:** desktop aggiornato e utilizzabile nella configurazione proposta anche quando una cattura individuale fallisce.
- **Evidenze:** [rifiuto e limite](VERIFICATION.md#24-ottobre--pacchetto-completo-dwm-e-rifiuto-iniziale-della-cattura).

### GFX-007 — Fence Wait/Signal e pubblicazione GPU

- **Stato:** difetto aperto; soluzione protetta qualificata non disponibile nel lavoro documentato. Sono ritirati i tentativi di correzione, non il problema. La precedente sintesi «candidate ritirate» ometteva il difetto osservato con il driver ufficiale. Attività esplicita in TODO-016.
- **Verificato il23 ottobre:** con driver ARM64 Microsoft-signed v0.4, due device hardware e query EVENT nuova, Wait(fence,1) non trattiene Clear/Copy: pixel nuovi leggibili con fence ancora0, poi Signal porta il valore a1. Host Neptune/DXMT con modifiche locali, non UTM intatto. È un errore di ordinamento reale oltre al feedback query; la sua causa interna completa e il legame con tutti i guasti XAML/WGC non sono dimostrati. Nessun nuovo probe sulla IoT principale in questa revisione.
- **Upstream:** [commento di FedericoDeBona nell'issue8](https://github.com/osy/kvm-guest-drivers-windows/issues/8#issuecomment-6374085762), pubblicato su autorizzazione il23 ottobre. Issue aperta al controllo del25 ottobre, due commenti e nessuna risposta successiva al nostro. La issue originale tratta v0.3/XAML, il nostro commento il distinto Wait/Signal v0.4; nessuna conferma del maintainer attribuita per deduzione.
- **Tentativi distinti:** controlli circoscritti delle candidate hanno verificato attesa fino a Signal e pubblicazione dopo completamento, ma la candidata DWM provoca GFX-002. Non sono una soluzione adottata né una qualifica del driver ufficiale attuale.
- **Prossimo passo / sblocco:** correzione del collegamento fra scheduling WDDM e autorizzazione all'esecuzione host, oppure candidata upstream compatibile. La coppia finale driver/runtime deve conservare Secure Boot/CI e TESTSIGNINGfalse. Indagine possibile, distribuzione bloccata fino alla qualifica; non ripetere ora prove o riattivare driver ritirati per questo aggiornamento documentale.
- **Chiusura:** ordinamento Wait/Signal rispettato nel caso prima difettoso e percorso reale produttore/consumer corretto nell'app principale protetta, senza regressione DWM. Un GetData riuscito o il ritiro dell'esperimento non bastano.
- **Evidenze:** [riproduzione ufficiale v0.4](VERIFICATION.md#23-ottobre--wait-d3d11-non-trattiene-query-e-scrittura-dei-pixel), [segnalazione autorizzata](VERIFICATION.md#23-ottobre--confine-dello-scheduler-e-segnalazione-autorizzata-al-driver), [pubblicazione candidata](VERIFICATION.md#24-ottobre--pubblicazione-dopo-il-completamento-gpu-del-produttore), [fallimento DWM](VERIFICATION.md#24-ottobre--confronto-dwm-non-qualificato-fast-fail-e-recupero), [revisione documentale](VERIFICATION.md#25-ottobre--revisione-todo-e-difetto-di-sincronizzazione-gpu), [sorgenti storici](RETIRED_EXPERIMENTS.md).

### WIN-001 — Spostamenti casuali nel drag delle finestre individuali

- **Qualifica main0.2.5 circoscritta:** drag Notepad da(41,291) a(91,260)punti Mac, guest da(2130,140) a(2230,202)pixel: stesso spostamento a scala0,5, frame successivo accettato/presentato e transizione conclusa. Un monitor fisico soltanto; non prova stabilità generale o trasferimenti fra scale diverse. [Evidenze](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

- **Stato:** causa corretta e verificata nel clone, commit 21d206b; distribuzione ordinaria e altre configurazioni non qualificate. Posizione/metadati mouse sono acquisiti prima dell’accodamento, evitando coordinate ricostruite dopo lo spostamento della finestra Mac.
- **Prossimo passo / chiusura, se ripreso:** confezionare e qualificare il percorso individuale destinato all’utente. Il passaggio fra monitor resta WIN-003.
- **Evidenze:** [diario delle verifiche](VERIFICATION.md), correzione del drag del 24 ottobre.

### WIN-002 — Resize individuale in attesa del frame

- **Nuovo caso locale,26 ottobre:** dopo richiamo Notepad e apertura desktop, WGC pubblica1464×1238 mentre i bounds DWM/metadati descrivono1463×1238. Il gate rimane con presentedID7/requiredID8 e input sospeso; cloaking attivo e nessun nuovo errore GPU. Primo esito finale rettificato nel diario, nessun bypass Mostra comunque. Il seguito ritaglia soltanto l'eventuale riga/colonna finale di arrotondamento WGC di un pixel; differenze maggiori e gate restano invariati. [Evidenze](VERIFICATION.md#26-ottobre--riapertura-notepad-e-cloaking-dopo-input-non-client).
- **Esito del caso dispari locale:** guest b79d181a distribuito; prova bordo destro/1463pixel e poi richiamo libreria→desktop→finestra Mac riusciti con frame e bounds1463×1238, presentedID8/requiredID6 e input non sospeso. Stesso documento utente conservato, cloaking attivo e taskbar senza Notepad. Caso corretto, non chiusura generale di WIN-002.

- **Secondo Mac,26 ottobre:** dopo l'allineamento del motore, dialogo Notepad hardware/cloaked con frame706×209 accettato, submittedID2 ma presentedID0/transitionActive. Il menu Window lo seleziona, ma resta «La finestra sta impiegando più tempo». Annullamento tramite il controllo Mac di chiusura riuscito; main torna utilizzabile. Nessun bypass Mostra comunque, dialogo non qualificato. [Evidenze](VERIFICATION.md#26-ottobre--allineamento-completo-del-motore-sul-secondo-mac).

- **Qualifica main0.2.5 circoscritta:** resize Notepad2044×1078→1844×978pixel, Mac1022×539→922×489punti, primo frame pertinente presentato/transitionfalse e input riabilitato. Dialogo706×209pixel→353×105punti realmente visibile e Cancel riuscito. Input tentato troppo presto viene rifiutato; l’avviso «non ancora pronta» e l’attesa percepita restano da migliorare, senza indebolire il gate. [Evidenze](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

- **Rilievo diagnostico25 ottobre:** osservati callback Metal con `presentedTime=0`; il callback funzionale di readiness in WindowRenderer non verifica questo valore prima di chiamare onPresented. È un limite del criterio «già presentato», distinto dalle durate GPU e da un errore del command buffer. Non dimostrata la causa dei precedenti guasti, nessuna correzione del gate applicata. Richiedere una presentazione positiva nella futura qualifica. [Report](reports/2026-10-25-graphics-pipeline.md), [verifica](VERIFICATION.md#25-ottobre--pipeline-grafica-con-timestamp-gpu-e-presentazione).

- **Seguito launcher:** riaprendo il frontend, primo frame valido/già presentato ma attesa ancora attiva con requiredPresentationID2 e presentedID1. Metadati, conferma display e presentazione ora riconciliati in entrambi gli ordini; il solo timeout non alza l’ID richiesto. La riapertura corretta completa le due finestre già dal primo frame presentato, senza nuovo avvio delle app. È un caso distinto dal recupero WGC di GFX-003, non una sua chiusura. [Evidenze](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Stato:** caso corretto nel clone, commit 36378af; distribuzione ordinaria non qualificata. Il worker pubblica il frame già disponibile nel nuovo rettangolo prima di ricreare il pool WGC.
- **Prossimo passo / chiusura, se ripreso:** breve verifica del percorso individuale nel pacchetto destinato all’utente; non confondere questo guasto con il resize del desktop corrente.
- **Evidenze:** [frame valido al resize](VERIFICATION.md#24-ottobre--gate-pronto-prima-delluso-e-frame-valido-al-resize).

### WIN-004 — Finestra Mac visibile ma app Windows non attiva

- **Seguito0.2.6 distribuito:** attivazione nel processo target, mouse diretto al suo albero di controlli e visibilità host distinta. Notepad cloaked riceve clic/testo/Cmd+A/drag; Explorer naviga ma ricompare captureFrames0 dopo aggiornamenti a caldo (GFX-003 aperto). Corretto il filtro dei dialoghi già cloaked dal proprietario; Don't Save riuscito nel guest finale. Finestra Windows-only non esportata. Hook ARM64 per thread; fallback visibile osservato nella candidata mouse reale poi scartata. Compatibilità di altre app, menu e recupero/crash non qualificati: voce aperta. [Evidenze](VERIFICATION.md#26-ottobre--input-per-finestre-cloaked-e-distribuzione-026). Il precedente probe0.2.5 rifiutava la chiamata esterna e non aveva un input utilizzabile; il suo esito negativo resta nel diario.

- **Qualifica main0.2.5 circoscritta:** aggiunto ripristino del first responder quando la finestra diventa key. Notepad riceve «Prova N+1 nella main» dopo il frame pronto; click Cancel sul dialogo restituisce il documento. Non qualificate tutte le app o ogni ripresa del focus; voce mantenuta aperta. [Evidenze](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

- **Stato:** aperto per la qualifica generale; correzione circoscritta distribuita0.2.6 nella IoT principale.
- **Verificato:** avvio Notepad dal launcher, immagine nella finestra Mac ma testo rifiutato dal controllo focus con messaggio «L’app non è attiva in Windows». «Apri Windows», click nell’editor e ritorno alla finestra Mac ripristinano la scrittura. Il recupero non è una correzione dell’attivazione.
- **Prossimo passo:** correlare richiesta attivazione, foreground HWND guest e focus della finestra Mac, preservando il blocco dell’input verso un’app diversa.
- **Chiusura:** apertura/ripresa dalla main porta alla corretta app attiva e riceve input senza passaggio manuale nel desktop; nessun input deviato o documento duplicato. TODO-017/011.
- **Evidenze:** [report pipeline](reports/2026-10-25-graphics-pipeline.md), [diario](VERIFICATION.md#25-ottobre--pipeline-grafica-con-timestamp-gpu-e-presentazione).

### TRN-001 — Valutazione IVSHMEM

- **Stato:** valutazione di fattibilità chiusa con decisione di non adozione; prototipi e vecchi handoff rimossi. Non è un difetto del desktop corrente, che non usa IVSHMEM.
- **Risultato conservato:** memoria condivisa, pubblicazione/notifica e frame reali verificati nel clone; sul testo provato IVSHMEM raw non supera TCP+LZ4. Dirty region e compressione non hanno dimostrato un miglioramento generale di latenza. Nessuna promessa zero-copy o soluzione GFX.
- **Criterio soddisfatto:** prova end-to-end e confronto circoscritto con decisione motivata; nessun altro benchmark necessario per chiudere l’esperimento.
- **Evidenze:** [confronto e decisione](VERIFICATION.md#24-ottobre--ivshmem-frame-esatti-confronto-breve-e-decisione), [indice storico](RETIRED_EXPERIMENTS.md).

## Monitor e compatibilità

### WIN-005 — App cloaked ancora nella barra delle applicazioni Windows

- **Riaperto dalla successiva segnalazione dell'utente:** nuova istanza Notepad/PID7704 Mac-owned con captureStopped=false ma guestCloaked=false e cloakError «Hidden window input rejected:0x6». Un punto fuori dal client di un controllo figlio (bordi/scrollbar) veniva trattato come guasto dell'isolamento, con ripristino permanente della visibilità. Inoltre il richiamo dal launcher può ricreare il pulsante: la proprietà salvata non prova che DeleteTab sia ancora applicato. La verifica precedente non copriva questi percorsi; correzione/nuova qualifica descritte nel seguito del diario.
- **Seguito distribuito bad09cca:** input non-client ai figli gestito separatamente, punti fuori da entrambe le regioni ignorati senza inviare input altrove o rimuovere il cloaking. DeleteTab ripetuto all'attivazione anche con stato di ripristino già salvato. Sulla stessa istanza utente: richiamo dalla libreria, clic sulle due scrollbar, minimizzazione e richiamo verificati con cloakError=null; documento conservato. Primo tentativo riespone GFX-003, poi nuova misura del riferimento GPU e prova finale circoscritta riuscita. Non dichiarata compatibilità generale o chiusura dei guasti GPU. [Evidenze](VERIFICATION.md#26-ottobre--riapertura-notepad-e-cloaking-dopo-input-non-client).

- **Causa verificata,26 ottobre sul secondo Mac:** Notepad Mac-owned era su DISPLAY2 e DWM_CLOAKED1, ma il pulsante restava nella taskbar del desktop completo. La verifica precedente del solo attributo DWM non copriva la segnalazione dell'utente.
- **Correzione distribuita e verificata nel caso locale:** helper ARM64 rimuove la singola HWND con ITaskbarList::DeleteTab; conserva l'idoneità al pulsante per AddTab al rilascio/ripristino, senza cambiare gli stili della finestra. Gestito TaskbarButtonCreated per una nuova registrazione Shell; riavvio Explorer non qualificato.
- **Criterio circoscritto verificato:** stessa istanza Notepad/PID7352 visibile sul Mac, testo ricevuto e pulsante assente in Windows. Fermando temporaneamente il servizio, pulsante ripristinato; alla riconnessione di nuovo assente. Pacchetto canonico e build allineati al guest0bb7fa1315de. Nessun reboot Windows. GFX-003 ricomparso durante l'input resta aperto; altre app, pinning, Alt+Tab/Task View e recupero generale non qualificati. TODO-002 resta IN CORSO.
- **Evidenze:** [verifica e limiti](VERIFICATION.md#26-ottobre--cloaking-del-pulsante-nella-taskbar-windows).

### WIN-003 — Monitor N+1 e drag fra scale diverse

- **Secondo Mac,26 ottobre:** motore misto e driver originali installati sulla VM93be6687. Due uscite Windows3D+DOD, mapping del solo Mac attualmente collegato e DPI app192 verificati; la topologia persiste dopo il successivo avvio. Non è una prova di trasferimento fra monitor: i due esterni presenti al primo aggiornamento non sono più rilevati durante questa installazione. [Evidenze e limiti](VERIFICATION.md#26-ottobre--allineamento-completo-del-motore-sul-secondo-mac).

- **Stato corrente0.2.5 nella main:** un Mac1440×900@2→DOD2880×1800/DPI192,3D riservato2048×1152/DPI144; `mappedDisplays=1`/setup completo. Testo, drag, resize e dialogo/Cancel reali verificati. Mapping per monitor e limiti guest implementati; riserva privata app distinta dalla work area OS. Restano passaggio fra monitor/scale diverse (secondo Mac non collegato in questa fase), cambio monitor che può richiedere setup DOD esplicito/reboot, Snap/massimizzazioni e margine inferiore48punti della taskbar. Nessuna affidabilità completa dichiarata. Questo aggiornamento supera le descrizioni «nessuna main» dei passaggi storici sotto. [Evidenze](VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

- **Nuovo risultato nel clone, tre uscite protette:** primaria3D SUBSYS1101, due2D SUBSYS1100; SetupDiCallClassInstaller seleziona i driver originali per dispositivo senza riconfigurare l’altro. QueryDisplayConfig/SetDisplayConfig confermano tre schermi estesi:3D2880×1800 principale, DOD2880×1740 e3840×2100. Device D3D predefinito e cattura sono hardware. Stesso documento con nuovo testo visibile sulle tre uscite; configurazione/driver/accelerazione e protezioni conservati dopo nuovo boot. Implementazione opt-in e strumenti nel repository, candidata privata soltanto; non è ancora N+1 integrato nell’app principale. [Evidenze](VERIFICATION.md#25-ottobre--todo-001-alternative-protette-e-associazione-per-dispositivo).

- **Requisito aggiornato dall'utente:** account EV/Hardware Dev Center escluso; Secure Boot disattivato e TESTSIGNING solo se indispensabili **e solo in assenza di alternative realmente valide**. La prova mista protetta supera il precedente blocco di associazione e ha la precedenza. IDD ARM64 originale rifiutato dalla normale validazione del pacchetto; nessuna protezione ridotta, nessun driver auto-firmato adottato.

- **Ricerca Parallels, nessuna nuova prova VM:** REA sul miniport ARM64 originale27.0.3 identifica più sorgenti/uscite nello stesso adattatore e Coherence con agente/hook guest. Suggerisce di privilegiare il driver unico multischermo; non prova il nostro preciso schema N+1 né risolve il limite del KMD corrente. Implementazione nel clone e distribuzione main assenti; criterio di chiusura invariato. [Report](reports/2026-10-25-parallels-multimonitor.md), [evidenze statiche e limiti](VERIFICATION.md#25-ottobre--parallels-multischermo-ricerca-rea-e-fonti-primarie).

- **Prova precedente, esito negativo conservato:** QEMU accetta3D+2D; DOD302 ARM64 Microsoft-signed si carica nella copia con Secure Boot. DiInstallDevice mirato al secondo associa però DOD anche al primo, perdendo l’accelerazione; il ripristino3D sul primo coinvolge entrambi e lascia il secondo in codice43. Candidata host con sottosistemi1100/1101 distinti: stesso esito. SetupAPI conserva la riconfigurazione dell’altro dispositivo nella stessa operazione; non è una diagnosi di impossibilità generale del binding per istanza. Nessuna coppia di uscite estese qualificata, nessun trasferimento/DPI provato. Copia spenta, main conservata e riavviata con protezioni verificate. [Evidenze](VERIFICATION.md#25-ottobre--todo-001-prova-di-adattatori-misti-protetti).

- **Stato precedente, ora superato dall’incremento0.2.5 sopra:** tre uscite nel clone, una nella main; mapping/DPI non integrati. Sul terzo schermo il dialogo riceve il frame ma resta presentedID0/transitionActive e CUA fallisce con ScreenCaptureKit−3811: limite concreto, senza attribuirlo automaticamente a WGC, driver o al solo acquisitore. Non dichiarata la visibilità del dialogo dal frame ricevuto. La prima prova a due uscite aveva invece mostrato realmente il dialogo sul Mac.
- **Vincoli ancora validi:** il KMD ufficiale ha MAX_CHILDREN=1; `max_outputs` da solo non lo estende. Il runtime3D ha stato globale e rifiuta una seconda GPU3D; la strada scelta usa un solo device3D e DOD separati. Gli adattatori DOD non sono nuove GPU3D e il device di cattura hardware non misura il costo della composizione/copia fra adattatori.
- **Prossimo passo / chiusura:** verificare nella main0.2.5 un trasferimento finestra+dialogo fra due monitor Mac/scale diverse quando disponibili; poi cambio monitor e setup delle nuove istanze. Conservare mapping/DPI app già verificati. Chiusura solo dopo il percorso end-to-end pertinente, senza dichiarare i passaggi non eseguiti.
- **Nuove evidenze:** [launcher e limite N+1](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Evidenze:** [requisiti rinviati](RESTART_PLAN.md#direzioni-e-limiti), [valutazione](VERIFICATION.md#24-ottobre--valutazione-n1-monitor-isolamento-e-gpu-per-schermo).

### APP-001 — Creality / OpenGL

- **Stato:** rinviato su richiesta dell’utente. Apertura in modalità software non qualifica il rendering OpenGL o l’uso completo dell’app.
- **Prossimo passo / chiusura:** riprendere solo su priorità esplicita o necessità concreta, poi qualificare il percorso reale richiesto.
- **Evidenze:** [piano](RESTART_PLAN.md) e [prove Creality nel diario](VERIFICATION.md).
