# Driver grafico corrente

La base desktop usa il driver ufficiale ARM64 v0.4 firmato Microsoft, identificato in [guest/graphics-driver.json](../../guest/graphics-driver.json). Nel sistema di sviluppo: VioGpu3D Running, SYS cfbc713754c7, Secure Boot attivo e TESTSIGNING disattivato.

Il [resize personalizzato](custom-resolution.md) ora funziona attraverso la sequenza host dell’app; non richiede una modifica del KMD. L’app conserva la cornice Mac e conferma la risoluzione Windows effettiva dopo la notifica monitor. [Prova reale](../../docs/VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

Le candidate test-signed di scheduler, completamento, compositore e resize KMD sono ritirate dal ramo attivo su richiesta dell’utente. La prova del compositore aveva provocato arresti: nessuna promozione o correzione causale dichiarata. Patch e controlli sintetici sono recuperabili dalla [revisione precedente](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/graphics/driver); esiti negativi e limiti rimangono nel diario e nel [registro dei problemi](../../docs/KNOWN_ISSUES.md). Il vecchio clone Driver Trial è stato eliminato nella pulizia autorizzata: non usare i relativi helper o percorsi come configurazione operativa.

Non riattivare modalità test o candidate DWM per il normale resize. Per un nuovo intervento partire da un difetto concreto nelle app e mantenere driver, UMD/helper e runtime compatibili. [Piano corrente](../../docs/RESTART_PLAN.md), [indice delle prove ritirate](../../docs/RETIRED_EXPERIMENTS.md).
