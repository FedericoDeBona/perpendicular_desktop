# Esperimenti ritirati dal ramo attivo

Il 25 ottobre 2026 l’utente ha scelto la base desktop con driver ufficiale e protezioni attive e ha richiesto di eliminare vecchie prove, codice e dischi VM. Il lavoro prosegue su `main`. Nessun nuovo ramo o archivio di dischi è stato creato.

Le prove e i fallimenti restano in [VERIFICATION.md](VERIFICATION.md). I sorgenti rimossi sono recuperabili dalla revisione completa [d5c02e3](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3), precedente alla pulizia:

**Recuperare IVSHMEM:** consultare `experimental/ivshmem` al commit `d5c02e3` su GitHub, oppure estrarlo fuori dal checkout con `git archive d5c02e3 experimental/ivshmem | tar -x -C /percorso/di/recupero` (directory già esistente). Valutazione e risultati: `docs/IVSHMEM_EVALUATION.md` al commit `3589194`. Git recupera sorgenti e documentazione, non i vecchi dischi/checkpoint eliminati. Il percorso attuale rimane invariato finché non si integra esplicitamente il codice recuperato.

| Prova ritirata | Sorgente storico |
| --- | --- |
| IVSHMEM, full frame, compressione e dirty region | [experimental/ivshmem](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/experimental/ivshmem) |
| WGC verso GPU: overlay guest/frontend e diagnostica del prototipo | [experimental/wgc-gpu](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/experimental/wgc-gpu) |
| RDP e riferimento DOD/2D | [experimental](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/experimental) |
| KMD custom resize, scheduler/UMD/completion/compositore test-signed | [graphics/driver](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/graphics/driver) |
| Gate host D3D11 candidato e controlli sintetici delle fence | [renderer](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/graphics/renderer/experimental-d3d11-completion-gate.patch), [controllo](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/scripts/check-graphics-fence-wait.py) |
| Valutazione IVSHMEM e vecchi handoff di trasporto | [resoconto storico](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/docs/IVSHMEM_EVALUATION.md) |
| Analisi statica di Parallels e implementazione iniziale WARP | [evidenze statiche](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/docs/PARALLELS_EVIDENCE.md), [prima implementazione](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/docs/IMPLEMENTATION.md) |

Il renderer attuale contiene ancora l’export host introdotto durante WGC. Per non perdere i sorgenti di una parte realmente compilata, `wgc-export.inc`, `wgc-export-timing.patch` e la ricetta `scripts/rebuild-native-export.py` sono conservati accanto alle parti grafiche attive. La pulizia non ricompila né cambia il renderer; non rende attive le finestre individuali o il trasporto IVSHMEM.

I vecchi dischi e checkpoint rimossi non sono recuperabili da Git. Rimangono la VM attuale, quella ordinaria, la sorgente originaria e un checkpoint recente, descritti nel [piano corrente](RESTART_PLAN.md). Ricevute private, log e immagini compatti restano fuori dal repository. I vecchi percorsi nelle sezioni storiche del diario possono riferirsi a build o dischi ora eliminati: non sono istruzioni operative.

Anche la documentazione operativa è stata ripulita: rimossi i resoconti separati delle valutazioni concluse, gli handoff di build eliminate e le vecchie istruzioni kernel/WARP/RDP. README, implementazione, registro dei problemi e guide grafiche descrivono la base attuale. I problemi non risolti restano nel registro con il loro ambito e gli stessi ID; la rimozione di un esperimento non equivale alla soluzione dei suoi difetti.

In particolare il difetto Wait/Signal riprodotto con il driver ufficiale v0.4 e [segnalato nell'issue8](https://github.com/osy/kvm-guest-drivers-windows/issues/8#issuecomment-6374085762) resta aperto in GFX-007 e TODO-016. Qui sono ritirati soltanto i tentativi kernel/UMD/gate che cercavano di correggerlo; la sincronizzazione GPU non è una valutazione conclusa con successo.

La nuova richiesta di launcher riprende soltanto il percorso immagini GPU già presente nel worker installato: ora è nei sorgenti attivi `guest/src/windows/gpu.rs`, `macos/NativeWindowFrames.swift` e `macos/NativeTransport/gpu-receiver.*`, con endpoint legato alla VM selezionata. Non è il ripristino dei prototipi IVSHMEM o delle candidate kernel ritirate.


## 25 ottobre — Pacing del frontend a richiesta (non distribuito)

Due varianti CAMetalDisplayLink e una di presentazione con transazione UI sono escluse dalla0.2.4: troppi timestamp di presentazione zero oppure nessun beneficio qualificato/primo frame individuale bianco. Non è una conclusione generale sulle API Apple. Sorgenti e raw conservati privatamente in Research/Graphics-Latency-20261025; presenter precedente e VSync attivo mantenuti. La0.2.4 distribuisce soltanto consegna diretta alla UI e riduzione delle pubblicazioni di stato invariato. [Esiti e limiti](reports/2026-10-25-graphics-latency-update.md), [verifica](VERIFICATION.md#25-ottobre--tentativi-di-riduzione-latenza-e-ui-024).
