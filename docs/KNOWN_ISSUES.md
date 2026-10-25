# Registro dei problemi

Aggiornato il 25 ottobre 2026. Leggere questo file prima di iniziare o riprendere, poi [RESTART_PLAN.md](RESTART_PLAN.md). Qui sono descritti stato corrente, prossimi passi e criteri di chiusura. La cronologia delle prove e dei fallimenti resta in [VERIFICATION.md](VERIFICATION.md); gli esperimenti ritirati sono indicizzati separatamente in [RETIRED_EXPERIMENTS.md](RETIRED_EXPERIMENTS.md).

## Base corrente e priorità

Si prosegue su `main` con il nuovo launcher delle sole app Windows (Launcher-20261025/build-5) nella VM di sviluppo c9f319b7. Driver ufficiale Microsoft-signed cfbc713754c7, Secure Boot attivo, TESTSIGNING disattivato e Code Integrity attiva confermati anche dopo l’aggiornamento. Il runtime grafico è invariato. Il launcher usa frame GPU delle finestre e frameChannel=true; il desktop mantiene lo scanout nativo. Resize reale 1920×1280, 1440×1676, fullscreen 2880×1800 e ritorno restano la precedente verifica desktop, con riscontro utente senza bande, distinta dalle nuove prove di catalogo/finestre. [Resize](VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate), [launcher](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).

La pulizia autorizzata ha rimosso vecchi clone, rollback, build e prototipi, recuperando circa 25,1 GB reali. Restano VM attuale, VM ordinaria e sorgente originaria, pacchetto/runtime in uso, sorgenti corrispondenti e un checkpoint recente. Il checkpoint precede la riattivazione di Secure Boot; percorsi e vincoli di ripristino sono nel piano. Nessuna nuova distribuzione nell’app/VM ordinaria è stata qualificata. [Ricevute e limiti](VERIFICATION.md#25-ottobre--pulizia-delle-vecchie-prove-e-base-corrente).

La nuova richiesta riprende launcher delle sole app Windows, finestre integrate e N+1: non sono più rinviati per priorità. Icone persistenti ad alta risoluzione, app principali, recenti e preferiti sono parte del launcher. Le candidate auto-firmate non sono selezionate e non vanno riattivate per il resize. Le loro anomalie restano documentate senza diventare una lista di prove da ripetere. La pulizia dei documenti operativi non chiude alcun problema grafico.

README, implementazione e guide grafiche sono stati ripuliti anche dalle istruzioni superate e dai riferimenti operativi alle build eliminate. [Revisione della documentazione e controlli](VERIFICATION.md#25-ottobre--pulizia-completa-della-documentazione-operativa).

## Come aggiornare il registro

- Aggiornare la voce esistente conservandone l’ID; crearne una soltanto per un difetto distinto.
- Distinguere requisito utente, ipotesi, risultato misurato e distribuzione effettiva. Collegare le prove nel diario senza accumulare qui i vecchi handoff.
- Chiudere solo dopo verifica del criterio indicato. Una riuscita di laboratorio o nel clone non qualifica l’app ordinaria o l’affidabilità generale.
- Conservare fallimenti nel diario e dati privati fuori Git. Non ripetere test senza modifiche pertinenti o nuove evidenze.

## Problemi pertinenti al desktop

### GFX-004 — Risorse grafiche indisponibili e recupero incompleto

- **Stato:** aperto, causa non isolata. In una sessione desktop il registro delle risorse raggiunge live256, rifiuta nuove registrazioni e il presenter diventa nero. Un reset adattatore recupera il percorso, senza dimostrare una correzione.
- **Verificato:** nel successivo uso di Calcolatrice, Settings/HDR e video le risorse passano da 40 a un picco di 79 e scendono a 37, con pending0/rejected0. La prova precede il ripristino del driver ufficiale; non qualifica durata indefinita né identifica la causa della saturazione. Il diario conserva anche perdita device, timeout e recuperi delle vecchie catture WGC.
- **Prossimo passo:** se il guasto ricompare nel desktop, correlare risorse ancora possedute da guest, renderer e contesti usciti prima di cambiare limiti o aggiungere retry.
- **Chiusura:** guasto identificato e risorse rilasciate, con desktop nuovamente utilizzabile senza spegnere l’intera VM.
- **Evidenze:** [saturazione e recupero](VERIFICATION.md#24-ottobre--ripristino-del-resize-personalizzato-del-desktop), [app reali e rilascio risorse](VERIFICATION.md#25-ottobre--verifica-del-desktop-accelerato-app-reali-e-rilascio-risorse).

### GFX-006 — Risoluzione e DPI errati dopo installazione a caldo

- **Stato:** aperto per la procedura di aggiornamento; recupero dopo avvio completo verificato nel clone. L’installazione a caldo può lasciare 1024×768/DPI96 e fallire l’applicazione di un modo pur accettato nella verifica API.
- **Prossimo passo:** prima di distribuire un aggiornamento definire il riavvio necessario e confermare geometria/DPI effettivi prima di riabilitare input e trasformazioni condivise.
- **Chiusura:** aggiornamento e riavvio eventualmente richiesto portano al display concordato; l’app non presenta come applicata una modalità non osservata.
- **Evidenze:** [installazione e recupero](VERIFICATION.md#24-ottobre--gate-pronto-prima-delluso-e-frame-valido-al-resize), [avvio protetto della base corrente](VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

### SYS-001 — Arresto HVF durante riavvio o arresto

- **Seguito launcher:** ricomparsa durante l’arresto regolare del vecchio pacchetto; controllo offline qcow2 con check-errors=0, nessuna riparazione o restore, successivo arresto/avvio riuscito. [Evidenze](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Stato:** aperto; assertion `(isv)` in `hvf_vcpu_exec`/hvf.c2378 osservata anche con KMD ufficiale. Nessuna causa attribuita al resize.
- **Verificato:** ricomparsa durante sostituzione/arresto del 25 ottobre; verifica offline del disco senza errori e successivo avvio con protezioni attive riuscito. Anche arresti ACPI completi riusciti; non sono una soluzione causale.
- **Prossimo passo:** se ricompare, conservare istruzione/MMIO e contesto del medesimo guasto prima di cambiare il gestore HVF.
- **Chiusura:** causa identificata e medesimo passaggio prima difettoso completato con il runtime corretto.
- **Evidenze:** [diario del ripristino protezioni](VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

### SYS-002 — Spazio host esaurito durante le scritture VM

- **Stato:** spazio recuperato e immagine riparata nel clone; prevenzione nel prodotto ancora aperta.
- **Verificato:** con 103 MiB liberi QEMU termina per `aio failed: No space left on device`. Riparati due cluster non referenziati, nessuna corruzione residua, Windows riavviato con volume Healthy. La pulizia successiva libera 25.051.377.664 byte, con circa 46,4 GB disponibili al controllo del 25 ottobre; questo valore è un rilievo storico, non una misura aggiornata a ogni lettura.
- **Prossimo passo:** prima di distribuire definire controllo e segnalazione dello spazio host per evitare una terminazione cieca durante le scritture.
- **Chiusura:** spazio insufficiente gestito senza perdita dati e con errore utilizzabile nell’app; il recupero manuale non basta.
- **Evidenze:** [incidente e recupero](VERIFICATION.md#24-ottobre--driver-per-risoluzioni-personalizzate-preparazione-e-installazione-nel-clone), [pulizia autorizzata](VERIFICATION.md#25-ottobre--pulizia-delle-vecchie-prove-e-base-corrente).

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

## Finestre individuali ed esperimenti ritirati

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

- **Stato:** candidate ritirate; integrazione affidabile e beneficio reale non qualificati. Controlli circoscritti hanno verificato attesa fino a Signal e pubblicazione dopo completamento, ma la candidata DWM provoca GFX-002.
- **Prossimo passo, se ripreso:** risolvere la causa del guasto e dimostrare un beneficio su un difetto reale; non ripetere benchmark già superati senza modifica pertinente.
- **Chiusura:** eliminazione del problema concreto nell’app reale con driver/runtime compatibili, senza regressione DWM.
- **Evidenze:** [pubblicazione GPU](VERIFICATION.md#24-ottobre--pubblicazione-dopo-il-completamento-gpu-del-produttore), [fallimento DWM](VERIFICATION.md#24-ottobre--confronto-dwm-non-qualificato-fast-fail-e-recupero), [controlli e sorgenti storici](RETIRED_EXPERIMENTS.md).

### WIN-001 — Spostamenti casuali nel drag delle finestre individuali

- **Stato:** causa corretta e verificata nel clone, commit 21d206b; distribuzione ordinaria e altre configurazioni non qualificate. Posizione/metadati mouse sono acquisiti prima dell’accodamento, evitando coordinate ricostruite dopo lo spostamento della finestra Mac.
- **Prossimo passo / chiusura, se ripreso:** confezionare e qualificare il percorso individuale destinato all’utente. Il passaggio fra monitor resta WIN-003.
- **Evidenze:** [diario delle verifiche](VERIFICATION.md), correzione del drag del 24 ottobre.

### WIN-002 — Resize individuale in attesa del frame

- **Seguito launcher:** riaprendo il frontend, primo frame valido/già presentato ma attesa ancora attiva con requiredPresentationID2 e presentedID1. Metadati, conferma display e presentazione ora riconciliati in entrambi gli ordini; il solo timeout non alza l’ID richiesto. La riapertura corretta completa le due finestre già dal primo frame presentato, senza nuovo avvio delle app. È un caso distinto dal recupero WGC di GFX-003, non una sua chiusura. [Evidenze](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Stato:** caso corretto nel clone, commit 36378af; distribuzione ordinaria non qualificata. Il worker pubblica il frame già disponibile nel nuovo rettangolo prima di ricreare il pool WGC.
- **Prossimo passo / chiusura, se ripreso:** breve verifica del percorso individuale nel pacchetto destinato all’utente; non confondere questo guasto con il resize del desktop corrente.
- **Evidenze:** [frame valido al resize](VERIFICATION.md#24-ottobre--gate-pronto-prima-delluso-e-frame-valido-al-resize).

### TRN-001 — Valutazione IVSHMEM

- **Stato:** valutazione di fattibilità chiusa con decisione di non adozione; prototipi e vecchi handoff rimossi. Non è un difetto del desktop corrente, che non usa IVSHMEM.
- **Risultato conservato:** memoria condivisa, pubblicazione/notifica e frame reali verificati nel clone; sul testo provato IVSHMEM raw non supera TCP+LZ4. Dirty region e compressione non hanno dimostrato un miglioramento generale di latenza. Nessuna promessa zero-copy o soluzione GFX.
- **Criterio soddisfatto:** prova end-to-end e confronto circoscritto con decisione motivata; nessun altro benchmark necessario per chiudere l’esperimento.
- **Evidenze:** [confronto e decisione](VERIFICATION.md#24-ottobre--ivshmem-frame-esatti-confronto-breve-e-decisione), [indice storico](RETIRED_EXPERIMENTS.md).

## Monitor e compatibilità

### WIN-003 — Monitor N+1 e drag fra scale diverse

- **Stato:** richiesto nuovamente, non disponibile nella base attuale. Desktop con una sola uscita; secondo monitor, DPI e trasferimenti non qualificati. Direzione concordata: monitor Windows corrispondenti ai Mac più area «Apri Windows» riservata e pulsanti debug; non è isolamento dei desktop Windows.
- **Vincolo verificato il 25 ottobre:** il KMD ufficiale ha MAX_CHILDREN=1. La seconda GPU 3D non supporta hotplug e il QEMU corrente rifiuta due device virtio-gpu-gl anche all’avvio (prova in pausa senza dischi). Aumentare soltanto max_outputs non basta; nessun secondo monitor attivato, nessuna riduzione delle protezioni e nessun display fittizio dichiarato pronto.
- **Prossimo passo / chiusura:** serve un percorso grafico con più uscite e driver accettato con Secure Boot, oppure isolamento effettivo di più adattatori nel runtime. Qualificare due uscite reali prima di N+1, poi trasferire finestra/dialogo fra aree e scale conservando immagine, posizione e input. Il launcher mostra le sole uscite lette da Windows.
- **Nuove evidenze:** [launcher e limite N+1](VERIFICATION.md#25-ottobre--launcher-windows-cache-persistente-e-limite-n1).
- **Evidenze:** [requisiti rinviati](RESTART_PLAN.md#direzioni-e-limiti), [valutazione](VERIFICATION.md#24-ottobre--valutazione-n1-monitor-isolamento-e-gpu-per-schermo).

### APP-001 — Creality / OpenGL

- **Stato:** rinviato su richiesta dell’utente. Apertura in modalità software non qualifica il rendering OpenGL o l’uso completo dell’app.
- **Prossimo passo / chiusura:** riprendere solo su priorità esplicita o necessità concreta, poi qualificare il percorso reale richiesto.
- **Evidenze:** [piano](RESTART_PLAN.md) e [prove Creality nel diario](VERIFICATION.md).
