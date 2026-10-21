# Perpendicular Desktop

Applicazione Mac per trovare e usare applicazioni Windows eseguite in una VM locale, mostrando le singole finestre sul Mac.

La prima base usa un'installazione Windows clonata, con nuove integrazioni guest e senza accelerazione 3D. La pulizia della copia comprende agenti precedenti, attività di avvio, condivisioni e cartelle reindirizzate; non equivale a reinstallare Windows.

- [Piano essenziale e requisiti](docs/RESTART_PLAN.md)
- [Scelte tecniche, build, limiti e aggiornamenti](docs/IMPLEMENTATION.md)
- [Prima verifica e problemi emersi](docs/VERIFICATION.md)

Il frontend Mac è Swift/AppKit; servizio, sessione e acquisizione Windows sono Rust ARM64. L'app di sviluppo è `.build/Perpendicular.app`; la VM e la configurazione privata restano in `~/Library/Application Support/Perpendicular Restart/`.
