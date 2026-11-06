# Misurare la GPU per processo sul Mac

Usare **Metal System Trace di Apple Instruments**, disponibile con Xcode. Il percorso è stato verificato sul Mac M4 con Xcode/Instruments 27 e con il runtime effettivo di Perpendicular 0.2.83. Non richiede modifiche a Windows, ai driver o alla topologia degli schermi. La disponibilità dei dati e i permessi possono cambiare su altri Mac.

Dal repository, scegliere una cartella di output nuova, fuori da Git:

```sh
python3 scripts/measure-gpu.py --seconds 10 \
  --output-directory "$HOME/.local/share/perp-gpu-nuova-misura"
```

La registrazione dura 5–30 secondi; il salvataggio e l'esportazione richiedono altro tempo. Durante il campione mantenere lo stato che si vuole misurare. Per il riposo: Windows acceso e collegato, nessuna finestra Seamless e Desktop chiuso. Annotare lo stato prima e dopo: il solo nome della cartella non dimostra che la VM fosse inutilizzata.

Lo strumento conserva la traccia originale `gpu.trace`, le esportazioni XML, i log e `summary.json` in una cartella privata. La traccia si può aprire in Instruments per esaminare le singole esecuzioni. Contiene metadati di tutti i processi: non pubblicarla nel repository. Per analizzare nuovamente una traccia esistente:

```sh
python3 scripts/measure-gpu.py --trace /percorso/registrazione.trace \
  --output-directory "$HOME/.local/share/perp-gpu-nuova-analisi"
```

## Cosa significa il risultato

La tabella riporta i millisecondi coperti dagli intervalli GPU `Active` attribuiti a ciascun processo nella traccia. Gli intervalli sovrapposti dello stesso processo vengono uniti, evitando di contare due volte, per esempio, Vertex e Fragment contemporanei. Il JSON conserva anche la distinzione fra canali e dispositivo. Riferimenti XML, durata effettiva della registrazione e processi senza attribuzione vengono conservati o risolti esplicitamente; uno schema mancante produce un errore, non uno zero.

**Questi tempi non sono una percentuale di utilizzo dei core GPU o una misura di energia.** Attività di processi e canali differenti può sovrapporsi: non sommare le righe. Il lavoro attribuito a WindowServer comprende la composizione del sistema e non può essere assegnato automaticamente alla singola app che l'ha provocato. L'assenza di righe indica attività non osservata nel campione, non prova che ogni motore GPU consumi sempre zero. Validare la copertura con una breve prova attiva nota; non usare una traccia con interazioni come benchmark del desktop fermo.

La percentuale globale del driver, i contatori cumulativi AGX e gli intervalli di Instruments sono misure differenti. Non convertire `AppUsage.accumulatedGPUTime` in percentuali senza un contratto sulle unità e una calibrazione pertinente. La discrepanza fra questi valori non dimostra da sola che un'app di monitoraggio sia difettosa.

## Riscontro del 6 novembre

| Campione | Durata effettiva | Intervalli osservati |
| --- | ---: | --- |
| VM collegata, nessuna finestra Seamless, Desktop chiuso | 8,811 s | WindowServer 157,473 ms; Chrome GPU 52,449 ms; non attribuiti 0,083 ms; nessuna riga QEMU/renderer/Perpendicular |
| Desktop aperto con interazione nella shell Windows | 10,877 s | Renderer VM principale 285,734 ms; altri renderer presenti; Perpendicular 160,634 ms; WindowServer 5371,129 ms |
| Secondo riposo, stato verificato prima/durante/dopo la cattura | 10,827 s | Nessuna riga QEMU/renderer/Perpendicular, contatori immagini fermi; WindowServer 3605,110 ms, Codex Service 160,037 ms, Creality Print Mac 137,324 ms; app Mac diverse dal primo campione |

Il controllo positivo rileva quindi gli stessi processi assenti nel campione a riposo. Non è un confronto di prestazioni a parità di carico, né prova di zero consumo fisico della VM. Evidenze, tentativi non riusciti e limiti: [VERIFICATION.md](VERIFICATION.md#6-novembre--gpu-per-processo-e-schermi-non-usati).

`powermetrics --show-process-gpu` è un'altra possibilità Apple, ma richiede privilegi amministrativi e il supporto dipende dall'hardware. In questa sessione l'esecuzione ordinaria è stata rifiutata perché non privilegiata. Il nuovo `metalperftrace` ha raccolto un archivio, ma `overview` ha risposto `No session found`: non è stato interpretato come consumo nullo.

Apple descrive le durate GPU, i canali paralleli e gli strumenti di profilazione in [Discover Metal debugging, profiling, and asset creation tools](https://developer.apple.com/videos/play/wwdc2021/10157/) e nella [documentazione delle prestazioni Metal](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/).
