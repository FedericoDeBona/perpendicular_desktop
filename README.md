# Perpendicular Desktop

Launcher Mac delle app Windows di una VM locale, con accesso al desktop Windows accelerato. App principali, recenti/più usate, preferiti, ricerca e icone originali ad alta risoluzione conservate sul Mac.

Prima di iniziare o riprendere leggere il [registro dei problemi](docs/KNOWN_ISSUES.md), poi il [piano di lavoro](docs/RESTART_PLAN.md). Il lavoro prosegue su `main` dalla base scelta dall’utente il 25 ottobre 2026.

Nel sistema di sviluppo sono verificati desktop diretto tramite «Apri Windows», driver ufficiale ARM64 v0.4 firmato Microsoft, Secure Boot attivo e modalità test disattivata. Resize personalizzato, fullscreen e ritorno concordano con la risoluzione Windows effettiva; l’utente conferma assenza di bande. Il frontend è Swift/AppKit/Metal, il collegamento guest è Rust ARM64 e la VM usa QEMU/HVF con runtime Native3D Wire2.

Il nuovo launcher e la precedente verifica desktop riguardano i pacchetti privati indicati nel piano e la VM di sviluppo, nella cartella storica `Perpendicular IVSHMEM Trial`; il desktop non usa IVSHMEM. La VM ordinaria `Perpendicular Restart` e la sorgente originaria sono conservate separatamente. La build generica usa la VM ordinaria: non equivale al pacchetto privato qualificato. Percorsi e componenti esatti sono nel piano.

Restano aperti arresti HVF, saturazione storica delle risorse e gestione dello spazio host. Una breve verifica riuscita non certifica affidabilità generale o compatibilità con tutte le app. Esplora file ed Edge sono disponibili nel launcher e si aprono in finestre Mac tramite immagini GPU. Il difetto noto delle etichette mancanti in alcune catture resta aperto. N+1 è nuovamente richiesto ma non disponibile: il driver/runtime corrente non offre ancora le uscite necessarie. Creality/OpenGL resta rinviato.

- [Requisiti, base attuale e prossimi passi](docs/RESTART_PLAN.md)
- [Implementazione attuale, build e manutenzione](docs/IMPLEMENTATION.md)
- [Problemi aperti e criteri di chiusura](docs/KNOWN_ISSUES.md)
- [Diario cronologico delle verifiche e dei fallimenti](docs/VERIFICATION.md)
- [Indice degli esperimenti ritirati e recupero da Git](docs/RETIRED_EXPERIMENTS.md)

Vecchi prototipi, clone e rollback intermedi sono stati rimossi nella pulizia autorizzata. Le istruzioni operative descrivono la base attuale; i risultati storici rimangono nel diario e in Git.
