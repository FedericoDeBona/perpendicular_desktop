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


## Coerenza delle query EVENT fra driver e renderer

Wire1 non basta a certificare l'accordo sul feedback delle query: il DLL ARM64 v0.3 installato aggiorna il contatore in Begin, mentre il renderer corrispondente al pacchetto corrente conta End. EVENT è una query End-only. Nella prova reale GetData ordinario restituisce S_OK/TRUE ma DONOTFLUSH continua a restituire S_FALSE, anche dopo il completamento confermato. Evidenze binarie, sorgenti e limiti in docs/VERIFICATION.md.

`python3 scripts/check-graphics-query-feedback.py` controlla questa specifica proprietà attraverso il bridge già aperto. Crea un solo device hardware e una sola EVENT, esegue il primo End e due riusi e rilascia entrambi. Per ogni fase attende GetData ordinario al massimo500ms, poi verifica DONOTFLUSH al massimo100ms. Non installa componenti o cambia impostazioni. Restituisce0 per accordo nelle tre fasi,1 per discrepanza e2 per mancata esecuzione del controllo. Non è eseguito automaticamente a ogni connessione o durante la cattura ordinaria.

Un risultato positivo non rileva necessariamente un completamento prematuro condiviso da entrambe le chiamate: non certifica ordinamento GPU, tutte le query o WinUI. È un criterio necessario e circoscritto per qualificare una futura coppia guest/host; una coppia che fallisce non è qualificata dalla sola creazione riuscita del device. La coppia v0.3/Wire1 fallisce; il controllo non applica una correzione.

Non allineare soltanto il contatore host a Begin: questo lascerebbe riutilizzabile il risultato precedente delle query End-only. La correzione deve mantenere invalidazione guest e pubblicazione host coerenti. Il pacchetto ufficiale v0.4 ARM64 è un candidato distinto: il suo binario richiede Wire2 e non può sostituire soltanto il driver nel runtime Wire1 attuale. Niente sostituzione di DLL firmati, test-signing o dichiarazione artificiosa di compatibilità del protocollo.


I primi due candidati v0.4/Wire2 sono stati provati e ritirati: il numero Wire comune non basta. Il guest invia RESOURCE_UPDATE con header80byte/context_id a offset72, mentre la base host selezionata ne decodifica72. Anche correggendo quel campo e preservando il contesto D3D11 richiesto, il boot reale fallisce ancora durante la decodifica. In quel passaggio i due candidati e le patch sperimentali rimangono privati e il pacchetto ordinario conserva Wire1. Prima di un altro tentativo occorre identificare opcode e byte consumati al punto del guasto. VERIFICATION.md registra anche i due arresti ordinari falliti, il recupero da checkpoint e la successiva finestra hardware leggibile; nessuna qualificazione v0.4 viene dichiarata.


## Protocollo corrispondente al driver v0.4

La prova isolata successiva identifica il secondo confine errato: `ID3D11Device::CheckFeatureSupport`/`0xff00571e`,48byte dichiarati contro32consumati. Il guest trasmette il buffer sia in ingresso sia in uscita; il vecchio decoder lo considerava solo output. Non basta allargare RESOURCE_UPDATE o scartare i16byte residui: si perderebbe anche il formato richiesto dal chiamante.

Il generatore esatto è [osy/neptune-protocol f510a6e](https://github.com/osy/neptune-protocol/commit/f510a6e41ea89a6d626de4da9d9b02978a770e37), indicato anche dal file guest generato. Tutti i311file guest/client/comuni generati coincidono byte per byte con [virtio-win-mesa bf536bb](https://github.com/osy/virtio-win-mesa/tree/bf536bba65454900d782fa7417bc95c1608d7483/src/virtio/neptune/neptune-protocol). Il decoder host viene rigenerato interamente dalla medesima sorgente, sopra il renderer `cf5af71359b224a9a482e9b5a67f8160497dc951`. Il controllo circoscritto sul vero codec, prima del framing, passa48→48 e conserva `DXGI_FORMAT_A8_UNORM=65`; prima48→32 e formato0. Il nuovo framing del generatore non è la prova della correzione del contenuto.

`prepare-native-wire2.py` riproduce la preparazione su copie private: controlla i due archivi, i23input del trasporto nativo e il checkout Git pulito del generatore, applica le cinque patch di durata/ammissione/scanout, aggiunge `wire2-update-context.patch` e verifica l'inventario completo del peer. Rigenera i file host/comuni, conserva log e ricevuta e non installa né qualifica runtime. La patch RESOURCE_UPDATE richiede soltanto Wire2, conserva il contesto D3D11 nominato dal guest e non va applicata al runtime Wire1. La diagnostica temporanea del decoder è esclusa.

Esempio con percorsi privati già predisposti, usando Python con PyYAML6.0.3, Mako1.3.10 e MarkupSafe3.0.3:

```sh
python scripts/prepare-native-wire2.py \
  --base-archive /private/qa/upstream-base.tar.gz \
  --renderer-archive /private/qa/upstream-wire2.tar.gz \
  --protocol /private/qa/protocol-f510 \
  --reference /private/tools/graphics-rebuild-sync-channel-20261019 \
  --output /private/qa/new-source
```

Il source preparato è stato compilato con Meson sul profilo privato e2job. Il candidato con diagnostica passa il controllo EVENT anche tramite `--socket` della VM separata, apre il documento e Settings in hardware. WinUI/HDR conserva etichette mancanti; non è risolto. Il runtime finale senza diagnostica è compilato e firmato ma non ancora avviato. Il pacchetto ordinario resta Wire1: prove, hash e prossimo passaggio in VERIFICATION.md e RESTART_PLAN.md.


## Confezionamento della coppia finale

`package-native-wire2.py` confeziona il build privato verificato senza avviare Windows. Controlla hash di renderer/server non rilocati e ricevuta dei sorgenti, corrispondenza delle patch correnti e inventario del runtime di partenza. Conserva QEMU69c236476db8, backend1a704afafdb1 e le capacità di durata/ammissione/import/scanout. Riloca e firma soltanto renderer/server; gli hash finali devono coincidere con il candidato qualificato, a93c2e5e34a8 e0869b34035ac. Esclude la diagnostica temporanea e registra il contratto Wire2/f510. Non è un compilatore universale: richiede gli esatti output del profilo privato verificato. La ricetta Meson locale è conservata con quel build; una ricompilazione che produce binari diversi richiede una propria qualificazione e l'aggiornamento esplicito dei pin.

```sh
python3 scripts/package-native-wire2.py \
  --build /private/qa/repro-f510-relocated \
  --runtime /private/runtime/Native3D \
  --output /private/qa/Native3D-wire2
```

Il pacchetto non aggiorna VM o app e mantiene `runtime_verified=false` nella ricevuta: le prove reali sono documentate in VERIFICATION.md. Il runtime precedente va conservato intero insieme al checkpoint pre-installazione del driver; Wire1/v0.3 e Wire2/v0.4 sono coppie distinte. Il frontend accetta Wire2 soltanto con il renderer/protocollo/capacità specifici verificati, mantenendo il trasporto Mac3/descriptor2. Il semplice numero Wire2 non diventa un criterio sufficiente.

La successiva promozione del23ottobre ha portato questa coppia anche nel pacchetto ordinario: query EVENT coerente nelle tre fasi, documento e Settings hardware, Retina2940×1912/200%. Il vecchio v0.3/Wire1 è conservato per rollback con il proprio stato Windows. Settings/HDR conserva parti mancanti e l'ammissione WGC resta intermittente; non sono una capacità risolta dalla correzione delle query. Le evidenze finali e la portata della qualifica sono in VERIFICATION.md.


## Ricostruzione sul Mac con il riferimento window-recovery

Il Mac locale può conservare `graphics-rebuild-window-recovery-renderer-20261020` al posto del profilo `graphics-rebuild-sync-channel-20261019`. `prepare-native-wire2.py --reference-profile window-recovery-20261020` ammette soltanto il suo inventario nativo preciso (23 file, digest741c50e71c63); gli hash degli archivi upstream, il checkout del generatore, le patch e il confronto dei311file del peer restano obbligatori. Il profilo predefinito e la sua ricevuta rimangono invariati. Il preparatore non aggiorna QEMU/backend o Windows e non qualifica il risultato.

La build locale del23ottobre usa Meson1.12.1, Ninja1.13.2, Python3.11, PyYAML6.0.3, Mako1.3.10 e MarkupSafe3.0.3 in un ambiente privato. Ricetta Meson, sorgente preparato, log, ricevuta e runtime completo sono in `~/Library/Application Support/Perpendicular Restart/QA/wire2-local-20261023/`. Le opzioni sono quelle del profilo window-recovery, con include e pkg-config rilocati su copie; build release/Neptune/EGL, server e worker process,2job. Renderer/server ottenuti differiscono dalla coppia qualificata sull'altra macchina. Il confezionatore `package-native-wire2.py` resta vincolato a quella coppia originaria e non va usato alterandone gli hash per accettare questa build. Le prove locali e i componenti effettivamente conservati sono in VERIFICATION.md.
## Fence D3D11 Windows: violazione riproducibile dell'attesa

`python3 scripts/check-graphics-fence-wait.py` usa il bridge privato già aperto dall'app. Un solo controllo sul driver reale: due device hardware temporanei, una fence condivisa inizialmente0, un target64×64, una texture staging e una query EVENT. Non installa servizi, cambia impostazioni o tocca finestre/documenti. `--socket` seleziona una VM privata. Exit0 significa ordinamento/completamento coerenti in questo caso; exit1 significa controllo fallito, exit2 preparazione/esecuzione non qualificabile. Non eseguirlo automaticamente all'avvio o a ogni frame.

A accoda `Wait(fence,1)`, poi ClearRenderTargetView, CopyResource ed End(EVENT). Prima del Signal la query deve restare S_FALSE. Il readback successivo deve attendere il rilascio: un thread di B segnala1 dopo250ms per evitare un blocco indefinito del controllo su un'implementazione corretta. I valori reali della fence, non il solo tempo, determinano se i comandi sono passati prematuramente. Dopo il rilascio query/pixel devono essere completi. Gli oggetti sono rilasciati e il thread termina prima dell'uscita. Adapter e hash UMD sono raccolti mentre i device sono ancora vivi.

Risultato sul Mac locale, backend3fff2d025a3f e driver ufficiale v0.4: Red Hat VirtIO GPU hardware/flags0, DLL cf7cd403a6b8 e b62f463ec4e4 uguali al manifest. Wait restituisce S_OK, ma EVENT restituisce S_OK/TRUE e tutti i4096pixel ff336699 sono leggibili con fence ancora0; B porta poi la stessa fence a1. Il controllo termina correttamente exit1/consistent=false. È una violazione dinamica dell'ordinamento di quell'API, oltre al precedente semplice accordo GetData/DONOTFLUSH. Non dimostra da sola la causa dello specifico frame WGC parziale o un difetto di tutte le fence fra processi.

Il [contratto di Wait](https://learn.microsoft.com/en-us/windows/win32/api/d3d11_3/nf-d3d11_3-id3d11devicecontext4-wait) impone l'attesa prima del lavoro successivo; [le monitored fence WDDM2](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/native-gpu-fence-objects) trattengono i lavori dipendenti nel scheduler. Nel sorgente associato bf536bba, [tritonDDI.c](https://github.com/osy/virtio-win-mesa/blob/bf536bba65454900d782fa7417bc95c1608d7483/src/virtio/neptune/triton/tritonDDI.c) distingue i Signal/Wait del runtime dal contesto remoting; Flush inoltra al contesto nativo. Nel [KMD v0.4](https://github.com/osy/kvm-guest-drivers-windows/blob/v0.4/viogpu/viogpu3d/viogpu_command.cpp) GATE può trattenere il completamento DMA fino a un token GPU. Questi sorgenti indicano dove seguire l'associazione fra la timeline WDDM dell'app e la pubblicazione dei comandi Neptune; non sono una decompilazione o una patch verificata del DLL installato.

Una correzione deve mantenere Wait asincrona e collegare i comandi successivi alla stessa dipendenza del kernel. Aspettare la GPU soltanto in Map, aggiungere Flush nel readback o bloccare il thread CPU sul primo Draw non risolve correttamente quel contratto: l'app deve poter accodare A prima di inviare il rilascio da B sullo stesso thread CPU. Non indebolire la firma del driver o sostituire DLL firmati per provare una soluzione ipotetica. Nessuna patch al runtime ordinario introdotta da questa indagine; evidenze e fallimenti in VERIFICATION.md.

## Cattura multi_ring non disponibile senza fermare il rendering — 24 ottobre

Nella copia auto-firmata autorizzata, DWM con `NPT_PERF=multi_ring` espone un limite reale dell'host: LIVE_ENABLE richiede un solo ring, il rifiuto termina il worker e il broker chiude l'ammissione di tutti i contesti successivi. Anche una nuova creazione D3D11 indipendente fallisce. Il limite della cattura diventa così un guasto del rendering guest, prima della verifica delle fence.

[initial-capture-decline.patch](initial-capture-decline.patch) aggiunge una risposta interna LIVE_UNSUPPORTED/MULTI_RING fra il worker e il broker ricompilati insieme. È ammessa soltanto prima di abilitare la cattura, senza allocazioni private vive né catture effettuate. Il broker verifica identità/sessione/epoch, assenza di frame o budget precedenti e non ripete l'attivazione su quel produttore; espone `selected_capture_unsupported`. Un refresh già accodato dopo ENABLE viene consumato senza letture GPU soltanto nello stesso stato iniziale sicuro; una revoca già in viaggio conserva la propria conferma. Errori successivi o di identità restano chiusi. I controlli che proibiscono snapshot multi_ring e import non sicuri rimangono attivi. Non è supporto alla cattura multi_ring.

Applicazione al sorgente locale Wire2 preparato, dopo le patch di durata/import/selezione e shared-texture initialization; ricompilare **entrambi** renderer e server. Non usare il confezionatore della precedente coppia qualificata cambiandone i pin. Base dei quattro file `src/perp-sync/`:

| File | SHA256 prima della patch |
| --- | --- |
| live.h | 0d931e364fe7665073990f9ad01e90646b5704827ed80934b48fe438e018fc2d |
| proxy-broker.c | aeb86fd6c40caad16644dfafa69b36362c0ab80222a2a2a144adf012a7d457b8 |
| worker-prefix.inc | af2bc2f05000d08a0f974763a4724db42362c6c4949cd83e77e36ae43948a27b |
| worker-suffix.inc | 6723305de411ed91c5fcf87859f2130591a7b2a0e4ab23b6b3c27ba82943385c |

Build Meson release/Neptune/EGL, server e worker process,2job, medesimi include e dipendenze della build locale precedente. Patch inversa sul sorgente compilato riuscita. [check-initial-capture-decline.c](check-initial-capture-decline.c) include il broker reale e conserva i peer socket: rifiuto iniziale/idempotente, contesti successivi ancora ammessi, identità stale e budget precedenti respinti, revoca accodata ancora confermata. Passa insieme al precedente controllo di ammissione. Il primo stub chiudeva erroneamente i peer ricevuti, generando EOF durante il pump: corretto prima della verifica, nessuna deduzione di affidabilità da quel risultato iniziale.

Nel solo bundle privato, renderer rilocato/firmato c57051d36f4639cbbc4c3fc26f040dfbf7eddb54047645cd29235e6d5f3b5e50 e server11f23f52723310bf3529eef98fd1714185b4f4149e16e071584ba1e256e231ed; backend3fff2d025a3f invariato. Manifest e provenienza aggiornati, firma deep/strict riuscita. Avvio reale: rifiuto esplicito del contesto DWM7, nessuna chiusura globale, successivi device A/B creati, controllo fence completo riuscito e finestra Settings acquisita da WGC hardware/presentata sul Mac. È verificato il contenimento del guasto, non la disponibilità dello snapshot nativo: il desktop di recupero è nero. Nessuna promozione nel runtime ordinario; completamento GPU/pubblicazione e cattura su più code restano lavoro aperto.


### Gate di completamento D3D11 sperimentale

[experimental-d3d11-completion-gate.patch](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/graphics/renderer/experimental-d3d11-completion-gate.patch) estende soltanto GATE_WAIT al tipo ID3D11Fence, con lookup esplicito del tipo e riferimento conservato insieme alla scelta dei relativi slot COM. Il percorso D3D12 mantiene i propri slot, senza cast permissivi tra interfacce. La candidata guest e le prove hardware D3D11 sono descritte in [driver/README.md](../driver/README.md). Richiede l'abbinamento privato; nessuna qualifica D3D12 o del prodotto dal solo ramo preservato.

La nuova readiness patch è guest-only: conferma la creazione della coda del gate prima di usarne l'ID. Non cambia i limiti degli snapshot: il desktop a più code resta non supportato. Il resize WGC corretto non dimostra il completamento del produttore DWM né la risoluzione del flicker; conservati anche dispatch fallito e arresto non pulito della precedente sessione. Nessuna promozione del runtime sperimentale nell'app ordinaria.


## Pulizia del25ottobre

I prototipi WGC/IVSHMEM e la candidata del gate D3D11 sono ritirati dal ramo attivo; i riferimenti precedenti descrivono prove storiche. Risultati e sorgenti sono nell’[indice degli esperimenti](../../docs/RETIRED_EXPERIMENTS.md). Il runtime corrente è conservato senza modifiche. Le parti host ancora compilate sono mantenute qui come `wgc-export.inc` e `wgc-export-timing.patch`, con ricetta `scripts/rebuild-native-export.py`; non abilitano da sole la cattura delle singole finestre. Sorgenti e ricette private host-7 restano disponibili per il renderer effettivamente in uso.
