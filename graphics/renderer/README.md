# Renderer del desktop corrente

Il sistema di sviluppo usa Native3D Wire2 con driver ufficiale v0.4. Renderer `2dee2e93f270` e server `135dd051bbc7` sono una coppia: non sostituire un solo binario. QEMU, backend, percorsi e hash della base qualificata sono nel [piano](../../docs/RESTART_PLAN.md).

Il runtime del clone è autonomo; sorgenti e ricette del renderer effettivamente in uso sono conservati privatamente in `Perpendicular Research/WGC-GPU-20261024/host-7`. Il nome storico della directory non indica uso di IVSHMEM. Il nuovo launcher riprende il solo percorso immagini GPU del worker già installato: frameChannel=true per metadati/ACK delle finestre, mentre il desktop conserva lo scanout nativo. Non sono cambiati i binari del renderer.

## Contratti e sorgenti conservati

Il guest ufficiale richiede renderer `cf5af71359b224a9a482e9b5a67f8160497dc951` e generatore `f510a6e41ea89a6d626de4da9d9b02978a770e37`, come vincolato nel [manifest guest](../../guest/graphics-driver.json). Le versioni guest e immagini host sono distinte; Wire2 da solo non certifica la compatibilità.

Le patch conservate descrivono componenti del percorso grafico e ricette per basi specifiche:

- `context-retirement.patch`, `context-admission.patch` e `context-admission-channel.patch`: ritiro dopo raccolta effettiva del figlio, ammissione prima di creare il worker e mantenimento delle immagini ancora in uso. Le varianti di ammissione appartengono a basi diverse.
- `import-lifetime.patch` e `import-marker.h`: marker legato alla vita della risorsa, senza trattenere indefinitamente gli import COM.
- `resource-retirement.patch`: ritiro individuale delle risorse con identità e conferme del controllo host corrispondente.
- `scanout-selection.patch`: ritiro delle copie pronte non selezionate, preservando lease e lavoro GPU incompleto.
- `wire2-update-context.patch`: contesto D3D11 del guest conservato in RESOURCE_UPDATE; richiede il peer Wire2 corretto.
- `initial-capture-decline.patch`: rifiuto iniziale della cattura multi_ring non supportata senza chiudere globalmente i contesti. Non implementa lo snapshot multi_ring.
- `shared-handle-diagnostics.patch`: diagnostica opzionale e limitata delle API già rifiutate, senza implementarne il supporto.
- `wgc-export.inc` e `wgc-export-timing.patch`: export host ancora compilato nel renderer attuale, conservato dopo la rimozione del prototipo delle finestre individuali.

Le ricevute private identificano quali input appartengono a ogni build. Non applicare indistintamente tutte le patch a un runtime e non aumentare limiti o indebolire identità/readiness per aggirare un guasto.

## Ricostruzione e verifica

`prepare-native-wire2.py` prepara sorgenti da archivi, generatore e inventari pinned. `package-native-wire2.py` confeziona soltanto gli output della coppia originariamente qualificata; non è il confezionatore universale di host-7. I vecchi adattatori `rebuild-native-renderer.py` e `rebuild-local-graphics.py` richiedono le proprie basi e non aggiornano automaticamente il runtime Wire2 corrente.

`scripts/rebuild-native-export.py` conserva la ricetta dell’export host e richiede `.build/Native3D` e un riferimento coerente. La presenza dello script non dimostra che gli input di ogni ricetta storica siano ancora disponibili o che una ricostruzione identica sia stata verificata dopo la pulizia. Per cambiare il renderer partire dagli input privati host-7, produrre una nuova coppia, registrare provenienza e qualificare il passaggio interessato nell’app reale.

I controlli C accanto alle patch verificano confini circoscritti del broker; non qualificano il driver, tutte le app Windows o la durata della VM. Saturazione delle risorse, recupero e guasti WGC restano nel [registro](../../docs/KNOWN_ISSUES.md). Le candidate fence/DWM e IVSHMEM restano ritirati; non riattivarli per il normale resize o per la libreria. Il percorso finestre ripreso è in NativeWindowFrames e guest/src/windows/gpu.rs; non è il ripristino dell’intero prototipo storico.

Il difetto Wait/Signal del driver ufficiale v0.4, [segnalato upstream](https://github.com/osy/kvm-guest-drivers-windows/issues/8#issuecomment-6374085762), resta aperto in GFX-007/TODO-016. Ritirati sono i tentativi di correzione; né il loro ritiro né un gate di pubblicazione circoscritto dimostrano corretto ordinamento di tutto il lavoro GPU.

Le ricette dei vecchi build, le prove Wire1 e gli esperimenti fence sono stati tolti da questa guida. Restano nel [diario](../../docs/VERIFICATION.md) e nella [versione storica](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/graphics/renderer/README.md), con i fallimenti e i limiti originali.

## Inventario circoscritto della saturazione

`resource-inventory.patch` aggiunge alla lettura QMP esistente un elenco di al
massimo 256 voci: identità, proprietario, durata e presenza nel registro ordinario
virgl. Non legge pixel, titoli o dati delle app; non raccoglie messaggi, concede
catture o libera risorse. La presenza ordinaria non prova da sola ogni riferimento
ancora detenuto dal guest. Usare il confronto sullo stato effettivamente guasto.

La ricetta `scripts/rebuild-renderer-resource-inventory.py` richiede il profilo
compatibile M1 `host-source/host-build/venv` conservato per OpenGL28ottobre.
Verifica sorgente, archivio e ricette pinned; confronta tutte le sezioni Mach-O
con il runtime indicato e ricostruisce prima una base identica. Solo dopo produce
la coppia diagnostica in una directory privata, senza modificare app o VM:

```sh
python3 scripts/rebuild-renderer-resource-inventory.py \
  --reference "$renderer_reference" --runtime "$qualified_native3d" \
  --output "$fresh_private_output"
```

Non è una ricetta generica per l'altro Mac: uno scarto richiede ricostruire e
verificare la base compatibile. Per la sola QA conservare dipendenze e backend,
confezionare entrambi gli output, aggiornare i loro hash nel manifesto privato,
marcare `resource_inventory_candidate`, poi firmare e confrontare il runtime
realmente avviato. `check-monitor-runtime.py` rifiuta sia quel marker sia il codice
diagnostico nelle build ordinarie. La prova di replay e il primo inventario QA
sono nel [diario](../../docs/VERIFICATION.md#saturazione-del-registro-dopo-resize-consecutivi-nella-qa-89);
non dimostrano ancora causa della saturazione o fix del nero.

## Metadati per durata e proprietario — candidata

`resource-lifetime-metadata.patch` sostituisce la tabella globale del prototipo
con un nodo per risorsa ordinaria virgl. Conserva i limiti già esistenti di
256 sorgenti per produttore e 32 contesti: al più 8192 nodi da 72 byte, senza
cambiare budget di snapshot, lease o ammissione GPU. Il ritiro mantiene tutti
i controlli di identità e conferma; la fine del contesto libera i suoi
nodi. Una risorsa sconosciuta, un ID duplicato, un'allocazione fallita o il limite
per produttore continuano a rifiutare la cattura. Nessuna risorsa ancora usata
viene espulsa per lasciare posto al nuovo scanout.

Aggiungere `--resource-lifetimes` alla ricetta precedente produce la coppia
`production/` senza inventario e `diagnostic/` con
`resource-lifetime-inventory.patch`. Prima esegue sul vero broker il controllo
`check-resource-lifetime-metadata.c` con ASan/UBSan: più proprietari, conferma e
lease, vecchi epoch, assenza della risorsa normale e ricezioni che liberano i
nodi durante il primo import. L'inventario elenca al massimo 512 voci e riporta
anche totale e assenti, compresi quelli oltre il taglio.

Il nome `production/` indica soltanto l'assenza di diagnostica: questa candidata
non è ancora qualificata per l'app ordinaria. In una confezione privata marcare
`resource_lifetime_metadata_candidate`; il gate produttivo la rifiuta. Dopo la
QA occorrono pin/requisiti condivisi e confezionamento compatibile prima della
consegna, senza trasferire la coppia M1 indiscriminatamente su M4.

`tests/GraphicsResourcePressure.ps1` è la singola pressione Windows circoscritta:
230 texture condivise BGRA1×1 valide, tenuta di 35 secondi e rilascio garantito,
nessuna modifica degli schermi o scrittura di file. La geometria e il flusso vanno
osservati separatamente nell'app reale; la riuscita della fixture non li prova.
