# Perpendicular Desktop

Applicazione Mac per trovare e usare applicazioni Windows eseguite in una VM locale, mostrando le singole finestre sul Mac.

La prima base usa un'installazione Windows clonata, con nuove integrazioni guest e senza accelerazione 3D. La pulizia della copia comprende agenti precedenti, attività di avvio, condivisioni e cartelle reindirizzate; non equivale a reinstallare Windows.

La preparazione di una nuova copia della VM esistente conserva disco, EFI e TPM insieme. `scripts/prepare-machine.py --source /percorso/VM --qemu-img /percorso/qemu-img --dry-run` controlla la sorgente senza copiarla; senza `--dry-run` crea una nuova cartella privata, che deve essere assente, con UUID, MAC e token nuovi. Richiede la VM sorgente spenta e rifiuta file aperti, dischi con backing e firmware diverso da quello locale dichiarato nella configurazione.

La copia non importa configurazioni o credenziali dello sharing host. Il disco Windows conserva però agenti, credenziali e cartelle reindirizzate preesistenti: la clonazione non li rimuove né dichiara lo sharing già disattivato. La rimozione degli agenti e dello sharing precedenti è un passaggio esplicito separato dall’aggiornamento ordinario del nuovo bridge; applicazioni e documenti Windows restano conservati.

Il percorso locale 3D/Metal ha mostrato un'app Win32 individuale leggibile, con input e geometria condivisa sul primario 2880×1800 a 200%. Il rendering delle app WinUI moderne presenta ancora difetti; più monitor Windows non sono ancora integrati. `Perpendicular → Recovery Display` permette di riavviare Windows con il display standard mantenendo la preferenza grafica. Risultati e limiti effettivi sono nella verifica locale.

- [Piano essenziale e requisiti](docs/RESTART_PLAN.md)
- [Scelte tecniche, build, limiti e aggiornamenti](docs/IMPLEMENTATION.md)
- [Prima verifica e problemi emersi](docs/VERIFICATION.md)

Il frontend Mac è Swift/AppKit; servizio, sessione e acquisizione Windows sono Rust ARM64. L'app di sviluppo è `.build/Perpendicular.app`; la VM e la configurazione privata restano in `~/Library/Application Support/Perpendicular Restart/`.

Con l'app aperta, `scripts/control_guest.py status` e `scripts/control_guest.py execute 'C:\Windows\System32\cmd.exe' -- /c ver` permettono la manutenzione diretta attraverso il bridge, senza aprire una console Windows. Il comando usa l'utente interattivo, con tempo e output limitati; dettagli in [IMPLEMENTATION.md](docs/IMPLEMENTATION.md).
