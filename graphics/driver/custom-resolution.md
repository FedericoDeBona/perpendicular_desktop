# Risoluzioni personalizzate del desktop

Il desktop Windows segue il raster della vista Mac senza cambiare la cornice scelta dall’utente. Il percorso corrente usa il KMD ufficiale ARM64 v0.4 firmato Microsoft, Secure Boot attivo e modalità test disattivata. Non richiede una patch kernel.

Il frontend pubblica il target via RFB `SetDesktopSize`, attende 1 s, invia 0×0 per disconnettere il monitor, attende 1 s e ripubblica il target. Il primo invio aggiorna il modo custom prima dell’invalidazione della cache dei modi Windows. La sola sequenza 0×0→target è risultata insufficiente per una seconda misura personalizzata.

La transazione è seriale, con debounce al termine del resize e risposte associate alla richiesta corrente. L’app aspetta l’invio finale, legge la geometria Windows, applica se necessario tramite `display_configure` e conferma con una nuova lettura effettiva. Il risultato QEMU4 indica inoltro al driver, non applicazione del modo. Il ritorno API e la dimensione RFB non sostituiscono la verifica guest.

Limiti attuali: un monitor, 4096 pixel per lato e 8.388.608 pixel totali, con riduzione proporzionale oltre il budget. Punti Mac, pixel Retina e DPI Windows restano distinti. Non adattare la finestra Mac alla modalità Windows più vicina.

Nel pacchetto privato build-11, dopo avvio protetto, sono verificati 1920×1280 iniziale, finestra 720×838 punti@2→1440×1676, fullscreen 1440×900@2→2880×1800 e ritorno. Windows e scanout concordano, `nativeActive=true`, click Start riuscito; l’utente conferma assenza di bande fullscreen. Nessun cambio a QEMU, UMD o helper per questa correzione. [Prova reale e tentativi falliti](../../docs/VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

Le attese sono quelle verificate; latenza ottimale, durata generale, DPI percepiti costanti e crash a metà ciclo non sono qualificati. Lo stop accodato conserva la riconnessione, ma ciò non prova il recupero da interruzione del processo.

Il precedente esperimento test-signed è ritirato, con sorgenti e fallimenti recuperabili nell’[indice storico](../../docs/RETIRED_EXPERIMENTS.md). Le vecchie istruzioni di installazione o riduzione delle protezioni non fanno parte del percorso attuale.
