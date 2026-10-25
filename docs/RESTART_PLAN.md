# Piano di lavoro — desktop Windows su Mac

Prima di riprendere leggere [KNOWN_ISSUES.md](KNOWN_ISSUES.md), poi questo piano. Aggiornare il registro quando cambia una verifica e conservare prove e fallimenti in [VERIFICATION.md](VERIFICATION.md). Questo documento descrive lo stato operativo; gli handoff superati restano nel diario e nella [versione precedente](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/docs/RESTART_PLAN.md).

## Base scelta dall’utente

Il 25 ottobre l’utente approva resize, driver ufficiale e protezioni ripristinate, chiede pulizia delle vecchie prove e indica di proseguire da questo ramo. Ramo: `main`; base iniziale del desktop d5c02e3, seguita dal launcher descritto sotto. Nessun ritorno ai prototipi driver/RDP/IVSHMEM per deduzione.

La VM di sviluppo corrente è c9f319b7-6689-45ac-8003-b8e5fbaebbb8, nella cartella privata `~/Library/Application Support/Perpendicular IVSHMEM Trial`. Il nome storico non indica uso di IVSHMEM. Il nuovo launcher è in `~/Library/Application Support/Perpendicular Research/Launcher-20261025/build-5/Perpendicular Desktop.app`, frontend `1a4ecc0d5e13`; la precedente build-11 DesktopFocus resta conservata come base desktop di recupero.

Il worker corrente è `C:\ProgramData\PerpendicularWgcGPU\perp-launcher-3.exe`, SHA256 `84ab251698f6de3bd977dae5861916e191ec2c4f673d3187f77133b351f81228`, avviato dal task PerpendicularWgcGPUWorker. PerpendicularRestart resta Manual/Stopped nel solo clone: non avviare un secondo worker. Sorgente/binario corrispondenti e ricette del nuovo pacchetto sono conservati privatamente in Launcher-20261025; il vecchio current-guest-source DesktopFocus resta il riferimento del worker precedente.

Driver Windows ufficiale v0.4 Microsoft-signed cfbc713754c7 Running; Secure Boot attivo, TESTSIGNING=false e Code Integrity attiva. QEMU `64a5e90ee941`, renderer `2dee2e93f270` / server `135dd051bbc7`, backend `3fff2d025a3f` invariati. Runtime autonomo Runtimes/7f4667e8… della VM, con sorgenti/ricette host-7 conservati. Il launcher riprende il protocollo immagini GPU già presente nel worker precedente: endpoint associato alla VM, soli metadati TCP e nessun fallback pixel TCP/WARP. Il desktop conserva il proprio scanout nativo. La VM ordinaria Perpendicular Restart e la sorgente originaria non sono aggiornate automaticamente.

## Requisiti attivi

**Nuova richiesta del 25 ottobre:** launcher Mac unificato delle sole app Windows, moderno/pulito senza testi che spiegano il funzionamento; Esplora file ed Edge disponibili; icone Windows ad alta risoluzione con cache persistente; selezione iniziale delle app principali e recenti/più usate. Ripresa esplicita della direzione N+1 e delle finestre integrate: non sono più rinviate per priorità, ma capacità da implementare e qualificare mantenendo la base desktop protetta. Le descrizioni delle verifiche precedenti sul singolo monitor restano circoscritte.

- Launcher Mac delle sole app Windows, con app principali iniziali, ricerca completa, recenti/più usate e preferiti. Icone Shell originali a 256 px e cache persistente per VM, senza download ripetuto a ogni apertura. Nessun testo esplicativo sparso nell’interfaccia. «Apri Windows» resta accessibile; chiudere il frontend conserva sessione, app e documenti.
- La base qualificata ha un solo monitor virtuale; estendere verso N monitor corrispondenti ai Mac più area Windows riservata. Il desktop deve conservare resize reale della vista/fullscreen e cornice Mac scelta dall’utente. Lo scaling locale o il modo predefinito più vicino non bastano.
- Punti Mac, pixel Retina e DPI Windows restano distinti. Immagine nitida e trasformazione di input coerente; dimensione percepita/DPI stabili in ogni passaggio non ancora qualificati.
- Una riconfigurazione alla volta, risposte associate alla sessione/richiesta corretta e conferma delle dimensioni Windows effettive. Mai dichiarare applicato un modo dal solo ritorno API o RFB.
- Protezioni Windows attive. Non riattivare TESTSIGNING, candidate KMD o DWM sperimentali per il normale resize. Non modificare protezioni della VM ordinaria o del Mac.
- Driver e accelerazione devono dimostrare utilità nelle app reali. Distinguere rendering guest, trasporto e presentazione Metal; non dichiarare zero-copy o compatibilità generale dal solo desktop visualizzato.
- Mouse, tastiera, modificatori e scroll devono restare utilizzabili dopo resize e riconnessione. Un guasto non deve perdere documenti, duplicare app o lasciare tasti premuti.

## Percorso verificato e limiti

Il frontend pubblica il target, attende 1 s, invia uscita 0×0, attende 1 s e ripubblica il target. La prima pubblicazione aggiorna il modo custom prima dell’invalidazione della cache monitor. La sola sequenza 0×0→target era insufficiente. Il writer seriale conserva la riconnessione prima di uno stop accodato; l’app legge/applica e conferma dopo l’invio finale. Nessun cambio a QEMU/UMD/helper per questa correzione.

Dopo avvio con Secure Boot: 1920×1280 iniziale, finestra 720×838 punti@2→1440×1676, fullscreen 1440×900@2→2880×1800 e ritorno 1440×1676. Windows/scanout concordano, nativeActive=true, frameChannel=false e click Start riuscito. L’utente ha confermato assenza di bande fullscreen; GFX-008 riguarda soltanto acquisizioni automatiche, senza difetto visibile confermato. Non inseguirlo con nuove patch del renderer.

SYS-001/HVF, saturazione storica delle risorse e guasti WGC rimangono aperti secondo il registro. Il rilascio osservato e gli avvii riusciti non ne isolano la causa. Non cambiare limiti né riattivare la candidata DWM senza una riproduzione pertinente. Creality/OpenGL resta rinviato.

## Pulizia e dati da conservare

Pulizia autorizzata del 25 ottobre: vecchio clone Driver Trial, checkpoint intermedi e build/prototipi superati rimossi. Un solo checkpoint completo recente conservato: `Perpendicular IVSHMEM Trial/Rollback/before-graphics-20261025T090714Z`, driver ufficiale e TESTSIGNING off, immediatamente prima di riattivare Secure Boot. Il suo EFI precede SecureBootEnable=01; un eventuale ripristino deve tenerne conto e non va eseguito automaticamente. VM corrente, VM ordinaria e sorgente originaria restano distinte e preservate.

Launcher corrente, build-11 di recupero, runtime in uso, sorgenti dei worker e host-7, ricevute e risultati delle prove sono conservati. I vecchi esperimenti non sono più sorgenti attivi: [indice e recupero da Git](RETIRED_EXPERIMENTS.md). Le parti dell’export host ancora compilate nel renderer sono in graphics/renderer, senza ripristinare la cattura WGC individuale.

Le istruzioni operative sono state riscritte intorno alla base attuale anche in README, IMPLEMENTATION e guide grafiche. Le valutazioni concluse e le vecchie ricette sono consultabili da Git tramite l’indice; il diario rimane cronologico e contiene comandi, percorsi e stati validi al momento della singola prova, non istruzioni da eseguire sulla VM corrente.

Non ricreare i dischi/rollback eliminati né usare vecchi helper di ripristino riferiti a worker o clone rimossi. Prima di altra pulizia verificare dipendenze, file aperti e identità della VM; conservare documenti e modifiche utente. Dischi, credenziali, certificati e artefatti generati restano fuori Git. Ricevuta privata: Perpendicular Research/Cleanup-20261025/cleanup-receipt.json.

## Come proseguire

Scegliere il prossimo difetto concreto pertinente al desktop o un piccolo incremento richiesto dall’utente. Definire il risultato osservabile e la verifica minima, completarlo nell’app reale e proseguire. Evitare nuove matrici driver, benchmark fence ripetuti, grandi harness o cambi di edizione Windows senza una necessità dimostrata.

Conservare componenti separabili per controllo VM, collegamento guest, sessione, immagini/input e UI Mac. Swift/AppKit/Metal sul Mac e Rust nel guest sono la base attuale; nuove dipendenze o cambi architetturali richiedono una motivazione sul sistema effettivo. Consultare il vecchio progetto soltanto per una domanda precisa.

Verificare solo i passaggi interessati da una modifica. Una breve prova end-to-end prevale su molti controlli che replicano l’implementazione; aggiungere test soltanto per logica critica o dubbi concreti. Registrare anche i fallimenti, senza presentare una singola riuscita come affidabilità generale. Aggiornare documentazione, creare commit coerenti e fare push senza aspettare una nuova richiesta. Nessun push forzato.

Per una nuova distribuzione distinguere sempre il pacchetto privato funzionante dalla VM/app ordinaria: build-macos usa la directory ordinaria nei sorgenti generici, mentre il launcher privato sopra è configurato per la VM di sviluppo corrente. Non aprire o aggiornare l’altra VM per errore durante una verifica.

## Direzioni e limiti

Launcher, finestre integrate e monitor N+1 sono ripresi dalla nuova richiesta sopra; i vincoli che seguono ne descrivono il lavoro ancora da qualificare. La precedente priorità esclusiva al desktop non annulla questa richiesta. Le prove IVSHMEM/LZ4/dirty region e driver test-signed rimangono ritirate dal ramo attivo; risultati negativi e sorgenti storici sono recuperabili, non promossi.

Per le finestre individuali conservare il requisito di geometria percepita 1:1, controlli Windows sulle principali, popup/tooltip associati al proprietario e controlli Mac sui veri dialoghi. Resize al rilascio con anteprima locale; posizione/input e frame della geometria confermata devono usare lo stesso modello. Riconnettere la stessa app e documento senza duplicazioni. Se ripreso il trasporto solo GPU, non reintrodurre fallback pixel TCP/WARP per nascondere guasti.

N+1 è richiesto ma bloccato nella base attuale: KMD ufficiale con una sola uscita per adattatore e QEMU che rifiuta la seconda GPU 3D anche all’avvio. Non basta aumentare max_outputs e non sono stati attivati schermi fittizi. La direzione concordata prevede monitor Windows corrispondenti ai Mac più un’area desktop riservata e pulsanti per le uscite. È una proposta, non isolamento fra desktop Windows. Prima di estenderla qualificare due uscite, DPI e trasferimento di una finestra con dialogo. Non cambiare la topologia del desktop attuale come prerequisito di lavoro ordinario. Le osservazioni su Parallels sono evidenze statiche, non una ricostruzione verificata dei suoi interni.

RDP e il vecchio DOD/2D restano abbandonati. La precedente richiesta di rimuovere residui di altri Tools è stata superata dall’ordine di procedere con display/grafica: non riprendere inventari o disinstallazioni per completismo. La priorità resta l’uso del desktop attuale.
