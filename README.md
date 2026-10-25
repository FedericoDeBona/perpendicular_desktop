# Perpendicular Desktop

Applicazione Mac per usare un desktop Windows accelerato in una VM locale, adattato alla finestra Mac.

Per iniziare o riprendere il lavoro, leggere il [registro dei problemi](docs/KNOWN_ISSUES.md): è il riferimento per problemi aperti, correzioni da distribuire e prossimi passi. Il [piano](docs/RESTART_PLAN.md) conserva requisiti e vincoli; il [diario delle verifiche](docs/VERIFICATION.md) conserva prove e tentativi falliti.

La base scelta dall’utente è ora il desktop Windows diretto tramite «Apri Windows», con accelerazione locale, resize reale della risoluzione e driver ufficiale firmato Microsoft. Nel sistema di sviluppo sono verificati Secure Boot attivo, modalità test disattivata, finestra personalizzata e fullscreen con ritorno. Le finestre individuali sul Mac e i monitor N+1 restano obiettivi rinviati, non prerequisiti del desktop corrente.

Il lavoro prosegue su `main`. La pulizia del25ottobre ha rimosso prototipi e vecchi dischi di prova, preservando la combinazione funzionante e i documenti. [Base attuale e percorsi operativi](docs/RESTART_PLAN.md), [esperimenti ritirati e recupero dei sorgenti](docs/RETIRED_EXPERIMENTS.md). La VM attuale è nella cartella privata Perpendicular IVSHMEM Trial per ragioni storiche: il desktop non usa quel trasporto. La VM ordinaria Perpendicular Restart e la sorgente originaria sono conservate separatamente.

La coppia grafica usa il driver firmato v0.4 e il runtime Native3D Wire2 abbinato. La preparazione del CD controlla la compatibilità prima di aggiungere il driver; dettagli e verifica senza modifiche con `--dry-run` sono in [IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

La preparazione di una nuova copia della VM esistente conserva disco, EFI e TPM insieme. `scripts/prepare-machine.py --source /percorso/VM --qemu-img /percorso/qemu-img --dry-run` controlla la sorgente senza copiarla; senza `--dry-run` crea una nuova cartella privata, che deve essere assente, con UUID, MAC e token nuovi. Richiede la VM sorgente spenta e rifiuta file aperti, dischi con backing e firmware diverso da quello locale dichiarato nella configurazione.

La copia non importa configurazioni o credenziali dello sharing host. Il disco Windows conserva però agenti, credenziali e cartelle reindirizzate preesistenti: la clonazione non li rimuove né dichiara lo sharing già disattivato. La rimozione degli agenti e dello sharing precedenti è un passaggio esplicito separato dall’aggiornamento ordinario del nuovo bridge; applicazioni e documenti Windows restano conservati.

Nel percorso precedente delle finestre individuali sono stati verificati terminale e Notepad in finestre Mac, menu classici, salvataggio/apertura dai dialoghi e riconnessione. Il launcher mostra lo stato del processo e della cattura; Processi permette di ispezionare e terminare il singolo processo tramite guest agent. Il percorso verificato sul Blocco note classico usa WGC sul dispositivo hardware VirtIO GPU, readback a fasce, compressione LZ4 e presentazione Metal. Copie CPU, latenza variabile e saturazione delle risorse del renderer nelle sessioni lunghe restano limiti aperti; La compatibilità WinUI delle finestre individuali resta rinviata e non qualificata.

Il prodotto non è ancora considerato affidabile: restano perdita del device, primi frame incompleti, attivazione iniziale e compatibilità generale WinUI/3D. La geometria Retina2:1 è verificata sul solo monitor principale. Il desktop completo resta accessibile da Apri Windows; sulla nuova sorgente IoT il profilo RAMFB Standard/Recovery ha invece mostrato schermo nero. Più monitor Windows non sono ancora integrati. Risultati e limiti effettivi sono in VERIFICATION.md.

- [Piano essenziale e requisiti](docs/RESTART_PLAN.md)
- [Scelte tecniche, build, limiti e aggiornamenti](docs/IMPLEMENTATION.md)
- [Problemi aperti e stato delle correzioni](docs/KNOWN_ISSUES.md)
- [Diario delle verifiche e problemi emersi](docs/VERIFICATION.md)

Il frontend Mac è Swift/AppKit; servizio, sessione e acquisizione Windows sono Rust ARM64. La build generica produce `.build/Perpendicular.app` e usa la VM ordinaria Perpendicular Restart; l’app attuale build-11 è configurata per la VM di sviluppo scelta dall’utente. Consultare il piano prima di lanciare una build per non aprire la VM diversa.

Con l'app aperta, `scripts/control_guest.py --socket '/Users/federico/Library/Application Support/Perpendicular IVSHMEM Trial/Control/control.sock' status` seleziona il sistema di sviluppo attuale. Il comando generico `scripts/control_guest.py status` usa la VM ordinaria; `scripts/control_guest.py execute 'C:\Windows\System32\cmd.exe' -- /c ver` permette la manutenzione diretta attraverso il bridge, senza aprire una console Windows. Il comando usa l'utente interattivo, con tempo e output limitati; dettagli in [IMPLEMENTATION.md](docs/IMPLEMENTATION.md).
