# Piano di lavoro — desktop Windows su Mac

Prima di riprendere leggere [KNOWN_ISSUES.md](KNOWN_ISSUES.md), poi questo piano. Aggiornare il registro quando cambia una verifica e conservare prove e fallimenti in [VERIFICATION.md](VERIFICATION.md). Questo documento descrive lo stato operativo; gli handoff superati restano nel diario e nella [versione precedente](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/docs/RESTART_PLAN.md).

## Base scelta dall’utente

Il25ottobre l’utente approva resize, driver ufficiale e protezioni ripristinate, chiede pulizia delle vecchie prove e indica di proseguire da questo ramo. Base Git: `main`, risultato funzionale d5c02e3. Nessun ritorno ai prototipi driver/RDP/IVSHMEM per deduzione.

La VM di sviluppo corrente è c9f319b7-6689-45ac-8003-b8e5fbaebbb8, nella cartella privata `~/Library/Application Support/Perpendicular IVSHMEM Trial`. Il nome storico non indica che il desktop usi IVSHMEM. App aperta: `~/Library/Application Support/Perpendicular Research/DesktopFocus-20261024/build-11/Perpendicular Desktop.app`, frontend984011369cc5. Worker desktopd6d0da93aebc, PerpendicularRestart Manual/Stopped nel solo clone; non avviare un secondo worker. Sorgente e binario corrispondenti conservati privatamente in DesktopFocus-20261024/current-guest-source.

Driver Windows ufficiale v0.4 Microsoft-signed cfbc713754c7 Running; SecureBoot1, TESTSIGNING=false e Code Integrity attiva. QEMU64a5e90ee941, renderer2dee2e93f270/server135dd051bbc7, backend3fff2d025a3f. Runtime autonomo nella directory Runtimes/7f4667e8… della VM corrente; sorgenti/ricette host-7 conservati. Nessuna dipendenza di avvio dai vecchi clone o build rimossi. La VM ordinaria Perpendicular Restart e la sorgente originaria restano conservate; non sono state aggiornate o sostituite automaticamente.

## Requisiti attivi

- Aprire o ritrovare la VM e usare direttamente «Apri Windows», senza catalogo o catture individuali obbligatori. Chiudere e riaprire il viewer deve conservare la sessione e i documenti.
- Un solo monitor virtuale. Windows deve seguire la dimensione della vista e del fullscreen con una vera risoluzione applicata dal driver; la cornice Mac scelta dall’utente rimane ferma. Lo scaling locale o il modo predefinito più vicino non bastano.
- Punti Mac, pixel Retina e DPI Windows restano distinti. Immagine nitida e trasformazione di input coerente; dimensione percepita/DPI stabili in ogni passaggio non ancora qualificati.
- Una riconfigurazione alla volta, risposte associate alla sessione/richiesta corretta e conferma delle dimensioni Windows effettive. Mai dichiarare applicato un modo dal solo ritorno API o RFB.
- Protezioni Windows attive. Non riattivare TESTSIGNING, candidate KMD o DWM sperimentali per il normale resize. Non modificare protezioni della VM ordinaria o del Mac.
- Driver e accelerazione devono dimostrare utilità nelle app reali. Distinguere rendering guest, trasporto e presentazione Metal; non dichiarare zero-copy o compatibilità generale dal solo desktop visualizzato.
- Mouse, tastiera, modificatori e scroll devono restare utilizzabili dopo resize e riconnessione. Un guasto non deve perdere documenti, duplicare app o lasciare tasti premuti.

## Percorso verificato e limiti

Il frontend pubblica il target, attende1s, invia uscita0×0, attende1s e ripubblica il target. La prima pubblicazione aggiorna il modo custom prima dell’invalidazione della cache monitor. La sola sequenza0×0→target era insufficiente. Il writer seriale conserva la riconnessione prima di uno stop accodato; l’app legge/applica e conferma dopo l’invio finale. Nessun cambio a QEMU/UMD/helper per questa correzione.

Dopo avvio con Secure Boot:1920×1280 iniziale, finestra720×838punti@2→1440×1676, fullscreen1440×900@2→2880×1800 e ritorno1440×1676. Windows/scanout concordano, nativeActive=true, frameChannel=false e click Start riuscito. L’utente ha confermato assenza di bande fullscreen; GFX-008 riguarda soltanto acquisizioni automatiche, senza difetto visibile confermato. Non inseguirlo con nuove patch del renderer.

SYS-001/HVF, saturazione storica delle risorse e guasti WGC rimangono aperti secondo il registro. Il rilascio osservato e gli avvii riusciti non ne isolano la causa. Non cambiare limiti né riattivare la candidata DWM senza una riproduzione pertinente. Creality/OpenGL resta rinviato.

## Pulizia e dati da conservare

Pulizia autorizzata del25ottobre: vecchio clone Driver Trial, checkpoint intermedi e build/prototipi superati rimossi. Un solo checkpoint completo recente conservato: `Perpendicular IVSHMEM Trial/Rollback/before-graphics-20261025T090714Z`, driver ufficiale e TESTSIGNING off, immediatamente prima di riattivare Secure Boot. Il suo EFI precede SecureBootEnable01; un eventuale ripristino deve tenerne conto e non va eseguito automaticamente. VM corrente, VM ordinaria e sorgente originaria restano distinte e preservate.

Build-11, runtime in uso, sorgenti del guest installato e host-7, ricevute e risultati delle prove sono conservati. I vecchi esperimenti non sono più sorgenti attivi: [indice e recupero da Git](RETIRED_EXPERIMENTS.md). Le parti dell’export host ancora compilate nel renderer sono in graphics/renderer, senza ripristinare la cattura WGC individuale.

Non ricreare i dischi/rollback eliminati né usare vecchi helper di ripristino riferiti a worker o clone rimossi. Prima di altra pulizia verificare dipendenze, file aperti e identità della VM; conservare documenti e modifiche utente. Dischi, credenziali, certificati e artefatti generati restano fuori Git. Ricevuta privata: Perpendicular Research/Cleanup-20261025/cleanup-receipt.json.

## Come proseguire

Scegliere il prossimo difetto concreto pertinente al desktop o un piccolo incremento richiesto dall’utente. Definire il risultato osservabile e la verifica minima, completarlo nell’app reale e proseguire. Evitare nuove matrici driver, benchmark fence ripetuti, grandi harness o cambi di edizione Windows senza una necessità dimostrata.

Conservare componenti separabili per controllo VM, collegamento guest, sessione, immagini/input e UI Mac. Swift/AppKit/Metal sul Mac e Rust nel guest sono la base attuale; nuove dipendenze o cambi architetturali richiedono una motivazione sul sistema effettivo. Consultare il vecchio progetto soltanto per una domanda precisa.

Verificare solo i passaggi interessati da una modifica. Una breve prova end-to-end prevale su molti controlli che replicano l’implementazione; aggiungere test soltanto per logica critica o dubbi concreti. Registrare anche i fallimenti, senza presentare una singola riuscita come affidabilità generale. Aggiornare documentazione, creare commit coerenti e fare push senza aspettare una nuova richiesta. Nessun push forzato.

Per una nuova distribuzione distinguere sempre il pacchetto privato funzionante dalla VM/app ordinaria: build-macos usa la directory ordinaria nei sorgenti generici, mentre build-11 è configurata per la VM di sviluppo corrente. Non aprire o aggiornare l’altra VM per errore durante una verifica.

## Direzioni rinviate

Finestre Windows individuali sul Mac, WGC→GPU, monitor N+1 e launcher rimangono direzioni future, senza dipendenza dal completamento della pulizia. Le prove IVSHMEM/LZ4/dirty region e driver test-signed sono ritirate dal ramo attivo; risultati negativi e sorgenti storici sono recuperabili, non promossi.

Per le finestre individuali conservare il requisito di geometria percepita1:1, controlli Windows sulle principali, popup/tooltip associati al proprietario e controlli Mac sui veri dialoghi. Resize al rilascio con anteprima locale; posizione/input e frame della geometria confermata devono usare lo stesso modello. Riconnettere la stessa app e documento senza duplicazioni. Se ripreso il trasporto solo GPU, non reintrodurre fallback pixel TCP/WARP per nascondere guasti.

La direzione N+1 concordata prevede monitor Windows corrispondenti ai Mac più un’area desktop riservata e pulsanti debug per le uscite. È una proposta, non isolamento fra desktop Windows. Prima di estenderla qualificare due uscite, DPI e trasferimento di una finestra con dialogo. Non cambiare la topologia del desktop attuale come prerequisito di lavoro ordinario. Le osservazioni su Parallels sono evidenze statiche, non una ricostruzione verificata dei suoi interni.

RDP e il vecchio DOD/2D restano abbandonati. La precedente richiesta di rimuovere residui di altri Tools è stata superata dall’ordine di procedere con display/grafica: non riprendere inventari o disinstallazioni per completismo. La priorità resta l’uso del desktop attuale.
