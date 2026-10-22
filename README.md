# Perpendicular Desktop

Applicazione Mac per trovare e usare applicazioni Windows eseguite in una VM locale, mostrando le singole finestre sul Mac.

La macchina di sviluppo attuale è Windows 11 IoT Enterprise LTSC ARM64, importata da UTM in una copia APFS indipendente. La sorgente UTM viene conservata; il bridge Rust attuale e i driver firmati sono installati nella sola copia di sviluppo. Il percorso attivo usa VirtIO3D, ancora sperimentale.

La preparazione di una nuova copia della VM esistente conserva disco, EFI e TPM insieme. `scripts/prepare-machine.py --source /percorso/VM --qemu-img /percorso/qemu-img --dry-run` controlla la sorgente senza copiarla; senza `--dry-run` crea una nuova cartella privata, che deve essere assente, con UUID, MAC e token nuovi. Richiede la VM sorgente spenta e rifiuta file aperti, dischi con backing e firmware diverso da quello locale dichiarato nella configurazione.

La copia non importa configurazioni o credenziali dello sharing host. Il disco Windows conserva però agenti, credenziali e cartelle reindirizzate preesistenti: la clonazione non li rimuove né dichiara lo sharing già disattivato. La rimozione degli agenti e dello sharing precedenti è un passaggio esplicito separato dall’aggiornamento ordinario del nuovo bridge; applicazioni e documenti Windows restano conservati.

Sulla IoT corrente sono verificati terminale e Notepad in finestre Mac, menu classici, salvataggio/apertura dai dialoghi e riconnessione. Il launcher mostra lo stato del processo e della cattura; Processi permette di ispezionare e terminare il singolo processo tramite guest agent. Le immagini usano Metal e compressione LZ4 negoziata, con readback e copie CPU ancora presenti.

Il prodotto non è ancora considerato affidabile: restano scala/DPI, attivazione iniziale e compatibilità generale WinUI/3D. Il desktop completo resta accessibile da Apri Windows; sulla nuova sorgente IoT il profilo RAMFB Standard/Recovery ha invece mostrato schermo nero. Più monitor Windows non sono ancora integrati. Risultati e limiti effettivi sono in VERIFICATION.md.

- [Piano essenziale e requisiti](docs/RESTART_PLAN.md)
- [Scelte tecniche, build, limiti e aggiornamenti](docs/IMPLEMENTATION.md)
- [Prima verifica e problemi emersi](docs/VERIFICATION.md)

Il frontend Mac è Swift/AppKit; servizio, sessione e acquisizione Windows sono Rust ARM64. L'app di sviluppo è `.build/Perpendicular.app`; la VM e la configurazione privata restano in `~/Library/Application Support/Perpendicular Restart/`.

Con l'app aperta, `scripts/control_guest.py status` e `scripts/control_guest.py execute 'C:\Windows\System32\cmd.exe' -- /c ver` permettono la manutenzione diretta attraverso il bridge, senza aprire una console Windows. Il comando usa l'utente interattivo, con tempo e output limitati; dettagli in [IMPLEMENTATION.md](docs/IMPLEMENTATION.md).
