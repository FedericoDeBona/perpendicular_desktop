# Metadati del monitor primario Native3D

Il percorso RFB precedente azzerava `QemuUIInfo` a ogni richiesta di risoluzione. La patch conserva dimensioni fisiche, origine e frequenza già note e cambia soltanto i pixel richiesti. Il primo collegamento può inizializzare le dimensioni fisiche dai metadati del monitor Mac scelto al boot.

`HostDisplay` legge dimensioni fisiche CoreGraphics e UUID del monitor. Il frontend trasmette i tre valori pubblici insieme soltanto ai runtime che dichiarano `primary_monitor_metadata=1`. QEMU valida millimetri e UUID, annuncia le dimensioni fisiche nell'EDID del primo scanout e deriva dall'UUID un seriale numerico stabile a 32 bit. Tale seriale non conserva l'intero UUID e non garantisce assenza di collisioni. Non viene aggiunto un descriptor EDID testuale, per conservare gli slot usati dalle modalità flessibili già presenti.

Questo incremento riguarda un solo monitor e una sola identità selezionata all'avvio. Non realizza hotplug, più monitor, una modifica forzata dei DPI Windows o una correzione del rendering 3D. La scala effettiva deve ancora essere letta nel guest: i millimetri dell'EDID non annullano le preferenze di scala conservate da Windows.

`scripts/rebuild-native-monitor.py` verifica gli input QEMU corrispondenti, ricompila soltanto VNC e virtio-gpu-base, riutilizza i restanti oggetti verificati della stessa build e produce un nuovo runtime privato. Non modifica il riferimento, l'app o la VM e non cambia renderer/server/driver. Conserva patch, header, ricevuta e licenze nel nuovo runtime. Gli interventi a QEMU mantengono la licenza GPL-2.0-or-later del sorgente; l'header aggiunto è MIT.

```sh
python3 scripts/rebuild-native-monitor.py \
  --reference /percorso/graphics-rebuild-memory-reset-qualified-20261020 \
  --qemu /percorso/graphics-rebuild-qemu-20261019 \
  --runtime /percorso/Native3D-coerente \
  --output /nuova/cartella/privata
```

La verifica locale comprende compilazione, un controllo dell'header effettivo, versione QEMU, dipendenze/firma e tutti gli hash del runtime. Nessuna di queste prove avvia una VM. La successiva verifica mirata in Windows deve confermare pacchetto grafico effettivo, monitor/millimetri/identità annunciati, modalità applicata e DPI osservati prima di usare la geometria condivisa.

Il 21 ottobre 2026 è stato prodotto `.build/native-monitor-metadata4/Native3D`: entrambe le unità C compilate, QEMU 10.0.12, firma con entitlement Hypervisor e 27 hash del runtime verificati. I 1.186 oggetti/archivi riutilizzati coincidono con l'inventario della build corrispondente. Renderer e server conservano i propri hash. La ricevuta `Notices/Perpendicular/primary-monitor.json` conserva provenienza e verifiche, con `VM_started=false` e `runtime_verified=false`. Il controllo Swift 6 dei tre file host è passato e CoreGraphics ha restituito per il monitor reale 291×189 mm e un UUID; la UI ordinaria non è stata ricompilata o avviata in questo passaggio.

Sono conservati tre tentativi intermedi nelle directory private precedenti: mancava inizialmente l'header input modificato della stessa build; poi il trasferimento delle unità richiedeva la directory originale corretta per `trace.h`; infine libjpeg doveva essere individuata tramite il nome ABI, diverso dal nome fisico con versione completa. Il preparatore include ora l'header verificato, conserva il percorso degli include di ogni unità e risolve il nome ABI senza aggiungere dipendenze o modificare il riferimento. Questi errori di preparazione non sono prove di funzionamento o di errore nel guest.

La successiva integrazione nell’app ha confermato nel guest un EDID valido `Mac Display`, 291×189 mm e seriale numerico, con driver `oem4.inf` attivo senza errori SetupAPI. La modalità 2940×1912 è stata raggiunta, ma Windows ha scelto 250% invece del 200% Mac. Il resoconto aggiornato, inclusi il cambio inatteso di modalità e i difetti grafici, è in [VERIFICATION.md](../../docs/VERIFICATION.md). Le ricevute sopra descrivono il passaggio di build separato, precedente alla prova VM.

## Ricostruzione dalla base locale disponibile

Nel nuovo inventario del 21 ottobre i profili richiesti dai preparatori precedenti non erano più presenti. Il runtime dell’app installata coincide invece con le build `graphics-rebuild-resize-qemu-20261019` e `graphics-rebuild-resize-renderer-20261019`. `scripts/rebuild-local-graphics.py` è un adattatore separato, con pin espliciti di questa base; non modifica i pin degli altri preparatori.

L’adattatore verifica sorgenti, provenienza e 1.186 input di link; confronta anche la sezione codice di un relink senza patch col candidato originale. Ricompila due unità QEMU e cinque del renderer, applicando metadati del monitor e ritiro dei contesti. Renderer e server vengono aggiornati insieme al controllo host v2; Wire1, host-v3 e descriptor-v2 restano invariati. Conserva licenze, patch e ricevuta privata `Notices/Perpendicular/local-graphics.json`.

L’output locale `.build/local-graphics-v3/Native3D` ha superato compilazione, due controlli circoscritti degli header, verifica delle firme e dei 27 hash. La ricevuta mantiene `runtime_verified=false`: la preparazione non avvia Windows e non dimostra correttezza grafica, DPI o compatibilità nell’app.


## Richieste scanout soltanto con capacità del consumer

Il preparatore accetta `--consumer-demand` per modificare soltanto `qemu-native-sync.m`, preservando monitor, renderer, backend e driver del runtime verificato. Questa modalità è vincolata al QEMU confezionato4d0708b9e352 e al profilo qualified del20ottobre, con tutti i linker input e la ricetta di compilazione originali verificati. Un rebuild dei soli monitor rifiuta un runtime che dichiara già questa patch, per non eliminarla mantenendo un flag falso nel manifest.

`consumer-demand.patch` conserva una sola richiesta pendente durante assenza del client o saturazione dei due slot del publisher. Appena torna capacità invia una richiesta fresca; una nuova connessione a una sorgente statica conserva anche il refresh iniziale. Tick/pump, ACK e lease precedenti continuano a essere gestiti. Reset elimina la domanda della vecchia selezione. Nessun consumer nascosto, attesa del client o protocollo nuovo; il lavoro di rendering delle app Windows e WGC rimane separato.

`check-consumer-demand.c` include le funzioni tick/flush estratte dal sorgente effettivamente compilato, con sole dipendenze di confine inerti. Verifica zero richieste durante assenza/saturazione, accorpamento degli aggiornamenti, consegna finale dopo ritorno di capacità, nuova connessione statica e conservazione di pump/lettura già in corso. Il codice precedente fallisce il primo controllo, quello modificato passa. Non è una prova GPU o della VM. Il manifest dichiara scanout_consumer_demand1 e la diagnostica update_pending; risultati nell'app e limiti in VERIFICATION.md.
