# Backend grafico corrente

Il backend effettivo va identificato dal `runtime.json` e dai byte della libreria nel runtime usato dal processo QEMU corrente, poi confrontato con le correzioni condivise secondo [AGENTS.md](../../AGENTS.md). Il solo bundle canonico, la versione del frontend o il vecchio riferimento `3fff2d025a3f` non identificano tutte le macchine: sulla base M4 verificata il29ottobre è caricato `0bf5a8192263…`. Le patch e i preparatori di questa directory hanno basi precise; non costituiscono una build universale della combinazione attuale. Conservare l'abbinamento Wire2 identificato nel [piano](../../docs/RESTART_PLAN.md).

`named-errors.patch` aggiunge il nome dell’operazione a cinque messaggi generici, mantenendo risultato e frequenza del logger. Un messaggio nominato non dimostra da solo la causa di un difetto visivo.

`shared-initialization.patch` invia le inizializzazioni pendenti e attende il relativo evento GPU prima di esportare il descrittore di una texture condivisa. Al timeout di 1000 ms restituisce E_FAIL con handle nullo. Non sostituisce la sincronizzazione fra writer successivi e non modifica driver o protocollo guest. `tests/NativeSharedTextureChecks.cpp` verifica questo specifico confine con due device nativi; non qualifica tutti gli ordinamenti fra processi o la cattura Windows.

`native-bounded-capture.patch` resta diagnostica opzionale, non abilitata per l’uso corrente. Può catturare un solo worker selezionato con un marker privato; richiede un avvio diagnostico e può registrare pixel delle app. Non riattivarla o ricompilare il backend senza una domanda concreta pertinente al desktop.

`rebuild-native-backend.py` conserva input della vecchia base Wire1; non usarlo per sostituire automaticamente il runtime corrente. `rebuild-native-shared-initialization.py` richiede il proprio riferimento e runtime Wire2 pinned. Ogni output nuovo conserva una ricevuta, ma build e firma non dimostrano il funzionamento in Windows. Verificare gli input disponibili, preservare la coppia renderer/server e qualificare il passaggio modificato in una nuova copia privata.

Le vecchie istruzioni di cattura, i comandi di build legati a profili storici e i tentativi intermedi sono tolti dalla guida corrente. Restano nel [diario delle verifiche](../../docs/VERIFICATION.md) e nella [versione storica](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/graphics/backend/README.md).

## Candidata NV12 nativa, non distribuita

`nv12-native.patch` è il prerequisite per il decoder VP9: due texture Metal per un'immagine NV12, SRV di piano e trasferimenti coerenti. Deriva dalla [proposta di hadykachmarv-coder](https://github.com/3Shain/dxmt/issues/229), [gist](https://gist.github.com/hadykachmarv-coder/b8a3074182aa755f6bedde534481855e) revisione `822a74043048972717460b51688e23f739bebc1a`, adattata al nostro pin e alle sue firme/gestione BC. Le modifiche ereditano la licenza dei sorgenti DXMT (LGPL2.1-or-later); attribuzione e fallimenti conservati nel diario. La parte swapchain desktop della proposta non è inclusa.

La build ordinaria continua a usare il backend qualificato. La candidata include ora `vp9-video-device.patch`: VideoDevice/Context nativi e decodifica hardware VP9 profile0 verso NV12, verificati sotto. Il ponte DDI Windows è ora compilato, con buffer trasportati come risorse attraverso DecoderExtension; la verifica Windows e la condivisione NV12 fra processi restano aperte. Non cambiare la main né promuovere le capacità del browser in base al solo PASS nativo. I pin della ricetta sono in [video-inputs.json](video-inputs.json), non sostituiscono quelli del runtime di produzione.

Per ricompilare su un Mac ARM64, scaricare i tre archivi dagli URL esatti dell'input e conservarli fuori Git. Servono Xcode con il componente Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain` se assente), Python3.9+, Meson e Ninja. La ricetta verifica tutti gli hash prima di scrivere, ricostruisce la correzione shared-initialization esistente e rifiuta output preesistente o nel repository:

```sh
python3 scripts/rebuild-native-video.py \
  --dxmt-archive /private/path/dxmt-917b721.tar.gz \
  --headers-archive /private/path/directx-9df86f.tar.gz \
  --llvm-archive /private/path/llvm-15.0.7-arm64.tar.xz \
  --meson /private/tools/bin/meson \
  --ninja /private/tools/bin/ninja \
  --output /private/path/new-nv12-build
```

Sostituire i percorsi con quelli locali; non abbassare i pin per risolvere un rifiuto. Il pacchetto LLVM ufficiale serve per header/librerie LLVM15; la ricetta esclude la sua libc++ statica e usa quella dell'SDK. Compila con un solo job per contenere il carico insieme alla VM.

La libreria grezza è in `new-nv12-build/build/src/dxmt-native/libdxmt-native.dylib`, con ricevuta; non è firmata/confezionata per Perpendicular. Controllo minimo: compilare `tests/NativeVideoTextureChecks.cpp` e `tests/NativeSharedTextureChecks.cpp` con `c++ -std=c++20 -fms-extensions -Wno-extern-c-compat`, include `source/include/native/windows` e `source/include/native/directx`, link alla libreria privata e rpath alla sua directory. Eseguire gli eseguibili esterni al repository. Il primo controllo deve leggere entrambi i piani esatti dopo upload e update; il secondo deve conservare `ff336699` su entrambi i device. Non equivalgono a qualifica Windows/Edge o FPS.

[Baseline/candidata, audit e prossimo passo](../../docs/VERIFICATION.md#1-novembre--superfici-video-nv12-nel-backend-nativo).

## Decoder VP9 attraverso le API D3D11 native

`vp9-video-device.patch` si applica dopo shared-initialization e NV12; la ricetta richiede le tre patch iniziali e video-resource-submit.patch, con ABI e hash esatti. Aggiunge le interfacce video al device/context immediato nativo, un decoder profile0/8bit/4:2:0 e una sessione VideoToolbox che **richiede hardware** e ne controlla la proprietà effettiva. Contenuto cifrato e fallback software non sono supportati. Il processore SDR della candidata successiva è descritto sotto. Device/context conservano l'identità IUnknown e le superfici/decoder hanno riferimenti espliciti e controlli di dimensione/ownership. Deferred context non espone VideoContext.

Il primo passaggio dati è funzionale: VideoToolbox→copia NV12 sul Mac→UpdateSubresource verso i due piani GPU. Non è un percorso senza copie né una qualifica di60FPS. La protezione video resta non supportata; la successiva patch processor aggiunge solo le capacità SDR descritte sotto.

Controllo mirato, con gli eseguibili/output sempre fuori Git e `native_video_build` sostituito con l'output della ricetta:

```sh
native_video_build=/private/path/new-native-video-build
video_qa_dir="$(mktemp -d "${TMPDIR%/}/perpendicular-video.XXXXXX")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=3840x2160:rate=60' -frames:v 3 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -g 60 -f ivf "$video_qa_dir/three.ivf"
ffmpeg -hide_banner -loglevel error -i "$video_qa_dir/three.ivf" -frames:v 3 -pix_fmt nv12 -f rawvideo "$video_qa_dir/reference.nv12"
c++ -std=c++20 -fms-extensions -Wno-extern-c-compat -Wno-ignored-attributes \
  -I "$native_video_build/source/include/native/windows" \
  -I "$native_video_build/source/include/native/directx" \
  tests/NativeVideoDecodeChecks.cpp \
  "$native_video_build/build/src/dxmt-native/libdxmt-native.dylib" \
  "-Wl,-rpath,$native_video_build/build/src/dxmt-native" -o "$video_qa_dir/check"
"$video_qa_dir/check" "$video_qa_dir/three.ivf" "$video_qa_dir/reference.nv12"
```

Atteso:3frame pixel-identici, inclusi due frame interdipendenti dopo il keyframe. Il controllo verifica anche identità COM e rifiuto del descrittore fuori buffer. Il tempo totale include tre readback/verifiche, non è una misura FPS browser. Conservare anche i controlli NV12 e BGRA condivisa già descritti.

## Collegamento DDI sperimentale Windows

Gli stub COM GetDecoderBuffer/ReleaseDecoderBuffer restano presenti nel protocollo abbinato, ma WDDM gestisce i buffer come risorse D3D. `video-resource-submit.patch` usa l'esistente DecoderExtension per input senza puntatori e risorse per ID; l'ABI comune è `video-resource-submit.h`. Negoziazione1, massimo3 buffer,16MiB bitstream/64KiB metadata, offset/size/ownership e frame attivo obbligatori. Il controllo nativo precedente accetta anche `--resources`: verifica Map/Unmap, offset nonzero, rifiuto versione/range e tre frame pixel-identici. Non è un test del trasporto Windows.

`video-ddi.patch` aggiunge al Mesa/Neptune pin bf536bba le tabelle video DDI11.1/2.0/2.1 e il collegamento alle API host. Non include vecchie modifiche fence/presentazione. La UMD ARM64 si ricostruisce separatamente con pin in `video-umd-inputs.json`. Input esterni al repository: archivio Mesa, pacchetto WDK Microsoft ARM64, archivio LLVM15 e directory SDK/XWin con strumenti/librerie indicati nel manifest. Xcode21 e un ambiente Python con Meson1.9.1/Mako1.3.12 sono richiesti; il controllo rifiuta input differenti, senza modificarli.

```sh
python3 scripts/rebuild-video-umd.py \
  --mesa-archive /private/path/mesa-bf536b.tar.gz \
  --wdk-archive /private/path/wdk.nupkg \
  --llvm-archive /private/path/llvm-15.0.7-arm64.tar.xz \
  --windows-sdk /private/tools/windows-sdk \
  --meson /private/venv/bin/meson \
  --ninja /private/venv/bin/ninja \
  --output /private/path/new-video-umd
```

Output `build/src/virtio/neptune/triton/neptune_umd.dll`, file version100.6.101.58000, abbinata al kernel originale verificato, marcatura PrivateBuild `Perpendicular video-resource-v12` e ricevuta. `--prepare-only` ricostruisce sorgenti/configurazione senza dichiarare una build. Non crea un package installabile, non cambia KMD/DriverStore/registro/protezioni. La DLL modificata non è firmata Microsoft e si identifica esplicitamente come sperimentale. La versione numerica è quella richiesta dall’ABI del kernel originale; revisione candidata, hash e interfaccia privata1 restano controlli separati. Il prototipo iniziale0.4.0.1 non va registrato con il kernel100.6.101.58000. LoadLibrary in un processo Windows è riuscito; D3D11CreateDevice tramite driver software fallisce8007007f: non usare quel percorso come qualifica della UMD registrata.

La canonica continua sul runtime qualificato precedente. Prossima verifica: copia Windows isolata con normale registrazione UMD e kernel originale/protezioni conservate, tre frame corretti usando il normale percorso GetDecoderBuffer/SubmitDecoderBuffers (senza `--resources` nell'app Windows), poi browser reale. Non allentare i gate di produzione né promuovere questi soli risultati. [Verifica e limiti](../../docs/VERIFICATION.md#1-novembre--buffer-video-come-risorse-e-prima-umd-ddi).

### Esito Windows circoscritto e ripresa

La v3 (stesso kernel ABI100.6.101.58000) usa il valore2 nel descrittore buffer. Nel clone Windows M1 tre frame4K I/P/P hanno attraversato il normale GetDecoderBuffer/SubmitDecoderBuffers e il trasporto risorse verso VideoToolbox hardware, con NV12 pixel-identico al riferimento. Il valore1 si fermava al primo BufferInfo, prima del callback CreateDecoder. Il controllo Windows ora richiede VIDEO_SUPPORT e stampa i moduli caricati: la sola modifica del registro non bastava, è servito l'avvio completo. Nel clone sono preservati KMD originale/Secure Boot/CI/OpenGL; questa prova non qualifica il browser, la condivisione NV12 o60FPS. Le poche righe di traccia riguardano la creazione, non ogni frame. Lavoro in pausa su richiesta. [Evidenze e stato macchine](../../docs/VERIFICATION.md#1-novembre--primi-frame-windows-vp9-e-pausa).


## Superfici NV12 condivise native (2 novembre, candidata M4)

`shared-video-native.patch` estende il percorso POSIX shm già esistente a due
piani Metal nello stesso buffer: Y all'inizio, UV dopo `stride * height`.
Il descrittore conserva formato, stride, dimensione e fd del protocollo esistente.
Il controllo import verifica lo spazio per entrambi i piani; l'allineamento Metal
viene controllato prima di creare fd o mapping. Non cambia l'ABI del trasporto.
Per NV12 sono ammessi soltanto `D3D11_RESOURCE_MISC_SHARED`, una slice e usage
default; NT-handle e keyed mutex restano esplicitamente fuori dal nuovo supporto.
`video-named-errors.patch` conserva i cinque messaggi diagnostici nominati della
base ordinaria, adattati ai sorgenti della candidata. La ricetta verifica gli hash
di entrambe le nuove patch: non riusare il precedente PASS su un backend vecchio.

`tests/NativeSharedVideoTextureChecks.cpp` importa la superficie su un secondo
device, controlla i pixel Y/UV inizializzati, aggiorna dall'importatore e verifica
la vista del produttore dopo il rilascio dell'importatore. Compilarlo come gli
altri controlli nativi sopra. Baseline v3: creazione rifiutata80070057; candidata:
tre confronti pixel esatti. I controlli NV12 ordinario, BGRA condivisa e VP9
hardware3frame4K restano positivi. Sono verifiche native, non una prova di FPS,
condivisione tra processi Windows o risoluzione delle disconnessioni di Edge.

Per la UMD sul M4 è disponibile il profilo esplicito
`--toolchain-profile m4-clang-2100.3.34.2-llvm15`: Apple clang2100.3.34.2 e
`lld`/`llvm-ar`15.0.7 dal medesimo archivio LLVM fissato, esposti come lld-link e
llvm-lib. Header/librerie XWin e ABI KMD restano identici al profilo originale;
compiler/linker sono verificati per hash. Il profilo originale resta il default.
È richiesto anche PyYAML6.0.3, oltre a Meson/Mako già fissati. Gli strumenti
locali Rust non sono un sostituto: su questo Mac rust-lld non trova libLLVM.dylib.
Preparazione e compilazione della UMD non qualificano la sua esecuzione Windows.


## Processore video SDR sperimentale

`video-processor-format-support.patch` e `video-processor-native.patch` aggiungono un pass Metal reale per un singolo stream progressivo NV12/BGRA/RGBA verso BGRA/RGBA, con crop, scale, BT.601/709, range e alpha stream. `video-processor-ddi.patch` collega le API Windows al backend e trasporta l’esito effettivo delle creazioni e di Blt attraverso le risposte già presenti nel protocollo. I pin di entrambe le ricette sono obbligatori: una patch locale diversa viene rifiutata prima di creare l’output. La coppia non è ancora qualificata in Edge o distribuita nella main.

Il pass attende la coda D3D e il proprio completamento Metal: correttezza prima della misura prestazionale. AutoStreamCaps=0 non aggiunge filtri quando Windows abilita il suo stato automatico predefinito. Non sono annunciati NV12 output, HDR, filtri, stereo, interlace, conversione di frequenza o nuovi handle NT/keyed. `NativeVideoProcessorChecks.cpp` verifica nove conversioni native e dieci Windows sui pixel e il confine delle capacità; si compila con gli stessi include/link nativi indicati sopra. In Windows usa VIDEO_SUPPORT; il runtime può filtrare richieste di stati non annunciati e sintetizzare bit generici NV12 obbligatori: l’enumeratore specifico e le viste restano il gate effettivo. Non interpretare un test nativo come prova browser.

[Prove, negativi e punto di ripresa](../../docs/VERIFICATION.md#2-novembre--processore-video-sdr-reale-e-ponte-hresult).

L’ingresso NV12 supporta anche DYNAMIC/CPU write, osservato nel caricamento software di Edge: il processore legge la texture GPU dopo Unmap e attesa delle operazioni pendenti. Output e ingressi RGB restano DEFAULT. Il controllo pixel include Map WRITE_DISCARD, lifetime della vista e confronto con la baseline che rifiuta lo stesso descrittore; la sola riuscita nativa non qualifica il browser. I diagnostici riportano solo metadati della risorsa rifiutata, senza pixel; la UMD limita ai primi quattro i descrittori input per processo.

Per una diagnosi mirata, `PERP_VIDEO_TRACE_PATH` può indicare un file privato Windows: la UMD scrive soltanto i primi otto rifiuti Blt per processo (flag e codici colore, nessun pixel). Senza variabile non crea file. È una traccia opzionale, non un requisito operativo o una modifica delle capacità.

La revisione v10 diagnostica ha distinto i rami d’errore tramite HRESULT; la v11 ripristina gli errori standard. Il caso Edge ha identificato il solo blocco dei metadati HDR del display, che [l’API Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/d3d11_4/nf-d3d11_4-id3d11videocontext2-videoprocessorsetoutputhdrmetadata) distingue dal contenuto elaborato. La UMD accetta NONE/size0 e HDR10 ben formato come informazione del monitor senza cambiare i pixel SDR. Formati e colori HDR, metadata del contenuto HDR e metadati display malformati restano non supportati. Il controllo Windows confronta i pixel SDR prima/dopo il metadata display e interroga esplicitamente la conversione HDR non supportata. Questo non implementa tone mapping o output HDR.

Gli array di riferimento sinistri con conteggio zero sono ignorati e normalizzati dal bridge; conteggi nonzero e stereo restano non supportati.


La v12 aggiunge soltanto diagnostica ETW limitata (massimo32eventi per unità compilata/processo): marker CreateDevice e primo errore SetErrorCb, risultato host Map/GetData o callback Present. Nessun pixel, URL o contenuto utente; HRESULT e logica grafica invariati. Provider `48DCE1B6-E965-4E8A-B5FA-D9CB52657212`, keyword1, livello2. Il provider viene registrato, usato e rilasciato nella stessa chiamata, senza callback pendenti durante lo scaricamento della DLL. Gli errori ordinari WASSTILLDRAWING non vengono tracciati. Usare il collector QA in graphics/browser e verificare prima un marker proveniente dalla UMD effettiva; una traccia vuota non dimostra assenza di errori. La diagnostica non qualifica la fluidità o la stabilità di Edge.


## Candidata: immagine VP9 trasferita con blit Metal

`vp9-gpu-output.patch`, applicata dopo il processore SDR solo con l’opzione
`--gpu-output` della ricetta, importa i due piani
CoreVideo tramite CVMetalTextureCache sullo stesso device delle texture target.
Una copia Metal scrive Y/UV e la slice scelta dalla vista decoder. Elimina il
readback CPU dell'immagine NV12 e il successivo UpdateSubresource del percorso
precedente; il bitstream passa ancora attraverso le risorse/staging esistenti.
Non è quindi una pipeline interamente senza copie né una nuova API/protocollo.

Il passaggio conserva il completamento sincrono di EndFrame: prima termina il
lavoro D3D già accodato, poi mantiene le superfici CoreVideo e le viste fino al
completamento del blit. Controlla device, dimensioni, formati di piano, tipo e
slice; un errore Metal resta un errore, senza fallback software o pixel ridotti.
Il decoder continua a richiedere hardware VP9. Nessuna modifica UMD/kernel,
capacità, cifratura o protezioni. La ricetta verifica anche l'hash di questa
patch prima di generare output.

M1: tre frame I/P/P 4K esatti nel controllo nativo tramite risorse, anche nella
slice1 di una texture array, PASS. Il controllo condiviso NativeVideoDecodeChecks
ora legge quella slice per coprire il nuovo confine. Tre frame Windows nella
slice1 e regressione processore PASS. Primo Edge4K
incontra una disconnessione GPU, poi un campione mantiene hardware4K senza
nuovi crash ma perde357/1307frame (~27,3%); nessun vantaggio comparativo
qualificato. Il percorso CPU v12 resta quindi il default della ricetta: il tempo
totale dei tre readback non dimostra FPS o
riduzione degli scarti. Conservare la v12 confezionata per il confronto; il guasto
Map del M4 resta aperto e non è corretto da questa modifica.


## Traccia Map v13

`map-allocation-trace.patch` estende il provider v12 con descrittore della
risorsa Map e bytes/status/detail degli errori nei record, slot, pool e
allocazioni condivise Windows. La ricetta UMD verifica e applica il pin dopo
le due patch funzionali; ABI invariata, PrivateBuild v13. Stesso limite32
eventi per unità compilata/processo, nessun evento per frame riuscito, nessuna
modifica ai limiti o agli HRESULT. Il collector esistente decodifica i messaggi
UTF16 senza manifest. Un marker della DLL effettivamente caricata è necessario
prima di interpretare una traccia vuota. Questo è un passo diagnostico, non
una correzione dell'allocazione Map o una qualifica della fluidità.


## Pool condiviso Windows v14

Il caso Edge M1 v13 registra RES_INFO16MiB→C000009A prima di Map→reset,
anche quando la richiesta del pool è soltanto64KiB. La patch
`compact-shmem-fallback.patch` conserva il batching ordinario; se la creazione
fallisce, su Windows prova una sola volta la minima potenza di2 sufficiente
alla richiesta (almeno4KiB). Se fallisce anche questa, mantiene il vecchio
pool e restituisce il fallimento originale. Non aumenta la finestra BAR,
non cambia sincronizzazioni, HRESULT o protezioni e non risolve la mancanza
di spazio per richieste grandi. Marker ETW di recupero limitato al budget
esistente; nessun messaggio per frame ordinario.

La ricetta applica e verifica il pin della quarta patch dopo la v13.
`tests/NativeShmemPoolChecks.c` include direttamente il sorgente ricostruito
con un renderer che rifiuta le allocazioni: copre batching, retry compatto,
riferimenti/offset conservati sul fallimento e richieste grandi senza retry
inutile. Compilarlo con `PERP_SHMEM_POOL_SOURCE` impostato al percorso assoluto
di `src/virtio/neptune/npt_shmem_pool.c` della ricetta. Questa verifica isolata
non dimostra la stabilità Windows o FPS; entrambe richiedono la prova reale.

M1 Windows: moduli effettivi v14/tre frame array4K PASS,19recuperi da16MiB
rifiutati a64KiB riusciti nella traccia. Due brevi tratti Edge2160p60 fissi
senza crash (~5,84% e4,79%drop); confronto completo e stabilità ancora aperti,
nessuna promozione main. I grandi slot opzionali possono ancora non crescere:
il ring usa gli slot esistenti e attende i fence. La modifica non garantisce
allocazioni grandi né elimina tutte le attese; evitare i retry opzionali
ripetuti dopo un rifiuto è il prossimo passo circoscritto.


## Crescita opzionale del ring Windows v15

`bounded-map-growth.patch`, quinta patch verificata dalla ricetta UMD e applicata
solo con `--bounded-map-growth`, mantiene
la profondità già raggiunta quando una crescita opzionale viene rifiutata.
Evita che ogni DISCARD ripeta una creazione/mappatura Windows destinata a
fallire nello stesso ring. Si continua a scegliere fra gli slot esistenti e
ad attendere i loro fence; le allocazioni iniziali obbligatorie conservano
il comportamento precedente. Il cap dura quanto la risorsa: nuova risorsa,
nuova opportunità di crescita. Nessuna dimensione arbitraria o aumento limiti.
Marker ETW limitato `map growth capped` con dimensione dello slot e profondità
raggiunta; marker video/allocazione v15, formato descrittore Map v13 conservato.
Build/riproduzione sorgenti M1, moduli Windows/frame4K e quattro cap effettivi
PASS. Nel tratto sovrapposto Edgev15 ha194/1367drop contro62/1328v14, con
endpoint approssimati fino0,261s: nessun vantaggio qualificato, senza attribuire
causalità certa da un solo confronto. Il default della ricetta resta v14; la
v15 rimane un esperimento esplicito, senza promozione main.


## Riuso staging compresso, esperimento M1 del 2 novembre

`video-staging-reuse.patch` è disponibile con `rebuild-native-video.py --reuse-bitstream-staging`. Il default resta CPUv12; `--gpu-output` è una scelta distinta, non necessaria al riuso. La ricetta verifica entrambi i pin anche quando le opzioni sono disattivate e registra le scelte nella ricevuta. Un decoder conserva una risorsa stagingCPUREAD, cresciuta a potenza2 solo quando serve e comunque entro16MiB già ammessi dal protocollo. Il mutex serializza i submit; copia,MapREAD bloccante,Unmap e controlli ownership/range restano obbligatori. Nessuna lettura diretta di memoria CPUWRITE o bypass di sincronizzazione. Il vettore compresso conserva la capacità fra i frame.

Qualifica nativa su M1:3frame4K/offset16/slice1 pixel-identici,472file ricostruiti identici; 3frame4K Windows pure pixel-identici. Il confronto Edge nella stessa geometria non mostra vantaggio (15,31%drop base contro16,03%candidata, estremi approssimati), perciò resta solo opt-in e non promossa. Il profilo mostra creazione/readback per frame, ma non attribuisce tutti gli scarti all’allocatore. Per il confezionamento sperimentale partire dalla copia del runtime locale verificata29/29, sostituire il solo backend compilato, risolvere le dipendenze non di sistema verso le librerie già incluse con install-name relativo, firmarlo e verificarlo prima di aggiornarne l’hash nel runtime.json. Conservare patch e ricevuta della build in Notices/Perpendicular, marcarne esplicitamente la qualifica incompleta e verificare nuovamente tutti i membri. Non cambiare pin di produzione né trasferire librerie/runtime da un altro Mac. Il runtime immutabile effettivo e i moduli Windows vanno confermati al boot prima del confronto reale. [Evidenze](../../docs/VERIFICATION.md#2-novembre--riuso-bounded-dello-staging-bitstream).
