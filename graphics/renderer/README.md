# Fine dei contesti del renderer

La patch riguarda soltanto il renderer grafico Wire1 già incluso nel runtime. Non importa guest agent, sharing o codice dell'interfaccia precedente. La base è il renderer `d3c970599eb0bfbfe417b86d87fc0e0641da9512`, con la sua estensione host v3 e il backend corrispondente. I file modificati conservano le licenze MIT; anche l'header aggiunto è MIT.

Il broker precedente chiudeva definitivamente la cattura quando terminava il contesto selezionato. La patch fa attendere al server la reale raccolta del processo figlio dopo la terminazione già prevista dal renderer. Il server conferma identità ed esito; solo allora il proxy ritira il contesto senza chiudere la cattura. L'attesa del figlio ha un limite di un secondo. Un timeout o un esito non confermato continuano a chiudere la cattura. I descrittori delle immagini ancora usate dal Mac mantengono identità e durata indipendenti, e impediscono l'assegnazione di un nuovo budget finché non vengono rilasciati.

`rebuild-native-renderer.py` legge un profilo grafico di riferimento corrispondente e un runtime originale verificato, modifica copie private di otto file e ricompila cinque unità C. Produce una coppia renderer/server nello stesso nuovo runtime, con protocollo di controllo host versione 2. Il protocollo guest resta Wire1 e il trasporto delle immagini host resta v3. Il frontend abilita la conferma soltanto per un manifest che la dichiara. Non sostituire uno solo dei due binari.

```sh
python3 scripts/rebuild-native-renderer.py --reference <profilo-grafico-corrispondente> --runtime <Native3D-originale> --output <nuova-cartella-privata>
```

Gli hash del vecchio archivio, della libreria e del server sono vincoli espliciti dello script. Il risultato include patch e ricevuta in `Notices/Perpendicular`; la ricevuta di build non dichiara una prova runtime. Il profilo di riferimento, l'app e la VM non vengono modificati. Il runtime finale va incluso nel pacchetto e verificato con una breve prova nell'app reale.

`check-retirement.c` è un solo controllo mirato dell'header effettivamente compilato: rifiuta un processo figlio ancora vivo e conferma la raccolta del figlio dopo la terminazione. Si compila indicando la directory `build/source/src/perp-sync` dell'output. Non è una prova del driver o della compatibilità delle app Windows.

Questa patch non risolve esaurimento o riuso delle identità delle risorse, import condivisi non supportati, desktop protetto, DPI o più monitor. Le nuove diagnostiche distinguono le cause di rifiuto senza aumentare le capacità delle tabelle.
