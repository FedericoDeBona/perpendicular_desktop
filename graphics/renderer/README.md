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

## Rifiuto prima della creazione del worker

Per la base resize del 19 ottobre, `rebuild-local-graphics.py` applica anche `context-admission.patch`. Il proxy controlla il broker prima di chiedere al server di creare un contesto Neptune: il limite rimane 32. Il rifiuto per capacità, ID non valido o esaurimento degli epoch non modifica i contesti già presenti, i loro grant o le immagini ancora in uso e non chiude definitivamente la cattura. Il controllo e la creazione appartengono allo stesso thread chiamante del proxy.

L'allocazione del contenitore proxy precede la richiesta al server, quindi il suo fallimento non lascia un worker avviato. L'identità del contesto viene assegnata prima dell'inizializzazione: un errore successivo usa l'ID corretto nel percorso di distruzione e conferma già esistente. Anche un fallimento dell'aggancio al broker restituisce un errore di creazione e richiama quel cleanup. Le condizioni di errore non confermate continuano a chiudere la cattura secondo le protezioni esistenti; non vengono dichiarate terminazioni fittizie.

`check-admission.c` compila il broker effettivo con un solo sink per i messaggi di aggancio: riempie 32 slot, verifica che un rifiuto conservi stato ed epoch dei contesti sani e verifica il riuso dopo terminazione confermata. Non avvia processi grafici o Windows. Il candidato isolato del 21 ottobre ha superato questo controllo, compilazione/link dei componenti corrispondenti, firme e hash del runtime; la ricevuta dichiara `runtime_verified: false`. La correzione evita di accettare un nuovo contesto non registrabile. Non risolve né identifica l'eventuale stallo interno del worker in `GET_BLOB` e non certifica WinUI o Creality.

## Diagnostica facoltativa degli HANDLE condivisi

Anche `rebuild-native-renderer.py`, per la base host-v3 con `channel.h` disponibile sul Mac originale, applica ora l’ammissione prima della creazione del worker. Usa `context-admission-channel.patch`: conserva la configurazione non bloccante di entrambe le estremità del canale di quella base. La patch dell’altra base resize rimane distinta. Non mescolare i sorgenti o sostituire una sola libreria.

Il preparatore esegue il controllo C sul broker effettivamente compilato: riempimento dei 32 slot, rifiuto senza modificare i contesti sani, ritiro confermato e nuova ammissione. Manifest e ricevuta dichiarano `context_admission=1`. La ricompilazione ordinaria non include la diagnostica HANDLE opzionale e rimuove dal manifest un eventuale flag ereditato dalla variante di input.

L'opzione `--shared-handle-diagnostics` aggiunge soltanto un contatore alle sette API DXGI/D3D11 che il renderer già rifiuta: `GetSharedHandle`, i due `CreateSharedHandle`, `OpenSharedResource`, `OpenSharedResource1`, `OpenSharedResourceByName` e `OpenSharedFence`. Non cambia il risultato HRESULT né abilita nuove forme di condivisione. Lo script verifica anche l'hash del sorgente interessato, ricompila una sesta unità C e conserva una ricevuta separata. QEMU, backend DXMT, driver e protocolli rimangono quelli del runtime indicato.

Il renderer emette un messaggio iniziale di abilitazione e registra soltanto nome API, HRESULT e conteggio, con PID e data del logger esistente. Ogni contatore atomico per processo si ferma a 128; vengono scritti soltanto 1, 2, 4, 8, 16, 32, 64 e 128: al massimo otto righe per API e processo. Il valore 128 indica almeno 128 chiamate. Non sono registrati handle, puntatori, nomi di risorse, argomenti o contenuti guest. La diagnostica va usata in un runtime separato per una breve prova mirata, poi rimossa dall'uso ordinario.

```sh
python3 scripts/rebuild-native-renderer.py --reference <profilo-grafico-corrispondente> --runtime <Native3D-verificato> --output <nuova-cartella-privata> --shared-handle-diagnostics
```

La build separata del 21 ottobre 2026 ha superato compilazione, firma e verifica dei 27 hash del manifest; rispetto alla base cambiano soltanto renderer e server. Questa verifica non esegue il guest. La prova minima successiva consiste nell'aprire lo stesso documento di Blocco note e il menu una volta, correlando il PID del processo grafico ai contatori e all'eventuale cambio spontaneo di risoluzione. Nessuna chiamata non registrata può essere attribuita a queste API soltanto in base al generico messaggio `Not implemented`.

Nel precedente avvio reale delle 17:36 il testo del documento non appariva e in seguito risoluzione e DPI sono cambiati spontaneamente: il percorso non è considerato stabile. Lo stesso log contiene import/export interni riusciti di texture `A8_UNORM` (formato 65); questi usano il percorso condiviso interno e non dimostrano che le API HANDLE guest siano supportate. L'ispezione dei sorgenti corrispondenti conserva il formato 65 fino a Metal `A8Unorm`, senza un'incoerenza diretta di canale o swizzle individuata. Né l'ipotesi HANDLE né quella A8 costituisce una causa dimostrata del testo assente o del successivo blocco.

Nella prova successiva con questa variante il documento è diventato leggibile, ma la barra menu ha perso i glifi dopo un click su File. Il log non conteneva né il marker iniziale né righe `shared-handle reject`: la diagnostica resta inconclusiva e l’assenza di righe non dimostra assenza di chiamate. Il lavoro è stato fermato su richiesta dell’utente prima di verificare il motivo del marker assente. Nessuna causa grafica viene considerata risolta.

## Durata delle texture importate

`import-lifetime.patch` rimuove la tabella di256 riferimenti COM importati mantenuti fino alla chiusura del worker. L'informazione di importazione viene conservata nel private data della risorsa D3D11/D3D12, sotto una chiave casuale privata del processo host, mai trasmessa al guest. La distruzione della texture elimina anche il marker, senza un riferimento aggiuntivo che la trattenga; un nuovo oggetto allo stesso indirizzo non eredita la classificazione. La tabella delle sorgenti e il protocollo di ritiro/ACK rimangono invariati.

Lettura ambigua, interfaccia non supportata o scrittura non confermata chiudono la cattura, senza ammettere una sorgente sconosciuta. Il marker viene riletto dopo la scrittura; gli alias passano dalla stessa interfaccia della risorsa. La chiave non è un GUID costante indovinabile dal guest. Lo script ricompila la coppia renderer/server corrispondente e registra patch/header e `import_lifetime=1` nel runtime. Non modifica il backend DXMT o il protocollo guest.

`check-import-lifetime.c` usa il backend effettivamente incluso nel runtime:257 texture piccole contemporaneamente, riconoscimento attraverso un alias IDXGI, rilascio, nuova risorsa non marcata e dato malformato rifiutato. È un controllo mirato della logica critica, esterno alla VM; il ramo D3D12 non è verificato dal backend D3D11 attuale. La prova reale e i limiti rimangono in VERIFICATION.md. Non attribuire alla sola correzione ogni differenza dopo un riavvio.


## Cambio della superficie scanout sullo stesso produttore

`scanout-selection.patch` corregge un'attesa circolare nel broker: una copia pronta della vecchia superficie poteva restare in coda quando la selezione passava a un'altra risorsa dello stesso worker. Il consumer prende soltanto la selezione attuale; il ritiro delle altre copie dipendeva invece dall'ACK di una nuova copia, che poteva non trovare budget libero. Il pump ora ritira le copie di risorse non selezionate soltanto se pronte e senza lease. Non modifica copie GPU incomplete, immagini in uso dal Mac, epoch, limiti o conferme del produttore.

`check-scanout-selection.c` usa il broker compilato, un sink di controllo e pipe per gli eventi: cambio di risorsa sullo stesso worker, conservazione di un lease, conservazione di un evento non segnalato e consegna della risorsa attuale. Sul broker precedente fallisce il ritiro delle vecchie copie; sul corretto passa. Gli assert devono essere attivi. Non è una simulazione del driver Windows o una prova di rendering.

La proprietà QOM `perp-live-stats` aggiunge `renderer.pending_frames`, al massimo otto elementi: risorsa/contesto, epoch, generazione/batch, readiness, lease, corrispondenza con la selezione ed età. La lettura fa solo poll, senza consumare eventi o modificare lease. Il manifest dichiara `scanout_selection_retirement=1`; il protocollo non cambia. Il preparatore ricompila la coppia renderer/server preservando QEMU e backend del runtime compatibile verificato. La prova nell'app e l'incidente della diagnostica live sono riportati in VERIFICATION.md; il successo del desktop non certifica tutti i device loss o WinUI.
