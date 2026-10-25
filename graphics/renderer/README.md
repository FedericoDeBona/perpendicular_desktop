# Renderer del desktop corrente

Il sistema di sviluppo usa Native3D Wire2 con driver ufficiale v0.4. Renderer `2dee2e93f270` e server `135dd051bbc7` sono una coppia: non sostituire un solo binario. QEMU, backend, percorsi e hash della base qualificata sono nel [piano](../../docs/RESTART_PLAN.md).

Il runtime del clone è autonomo; sorgenti e ricette del renderer effettivamente in uso sono conservati privatamente in `Perpendicular Research/WGC-GPU-20261024/host-7`. Il nome storico della directory non indica che le finestre individuali siano attive: il desktop corrente usa `frameChannel=false` e scanout nativo.

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

I controlli C accanto alle patch verificano confini circoscritti del broker; non qualificano il driver, tutte le app Windows o la durata della VM. Saturazione delle risorse, recupero e guasti WGC restano nel [registro](../../docs/KNOWN_ISSUES.md). Le candidate fence/DWM sono ritirate; non riattivarle per il normale resize.

Le ricette dei vecchi build, le prove Wire1 e gli esperimenti fence sono stati tolti da questa guida. Restano nel [diario](../../docs/VERIFICATION.md) e nella [versione storica](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/graphics/renderer/README.md), con i fallimenti e i limiti originali.
