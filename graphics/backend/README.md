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

Output `build/src/virtio/neptune/triton/neptune_umd.dll`, file version100.6.101.58000, abbinata al kernel originale verificato, marcatura PrivateBuild `Perpendicular video-resource-v5` e ricevuta. `--prepare-only` ricostruisce sorgenti/configurazione senza dichiarare una build. Non crea un package installabile, non cambia KMD/DriverStore/registro/protezioni. La DLL modificata non è firmata Microsoft e si identifica esplicitamente come sperimentale. La versione numerica è quella richiesta dall’ABI del kernel originale; revisione candidata, hash e interfaccia privata1 restano controlli separati. Il prototipo iniziale0.4.0.1 non va registrato con il kernel100.6.101.58000. LoadLibrary in un processo Windows è riuscito; D3D11CreateDevice tramite driver software fallisce8007007f: non usare quel percorso come qualifica della UMD registrata.

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


## Processore video SDR della candidata v5

`video-processor-format-support.patch` e `video-processor-native.patch` aggiungono un pass Metal reale per un singolo stream progressivo NV12/BGRA/RGBA verso BGRA/RGBA, con crop, scale, BT.601/709, range e alpha stream. `video-processor-ddi.patch` collega le API Windows al backend e trasporta l’esito effettivo delle creazioni e di Blt attraverso le risposte già presenti nel protocollo. I pin di entrambe le ricette sono obbligatori: una patch locale diversa viene rifiutata prima di creare l’output. La coppia non è ancora qualificata in Edge o distribuita nella main.

Il pass attende la coda D3D e il proprio completamento Metal: correttezza prima della misura prestazionale. AutoStreamCaps=0 non aggiunge filtri quando Windows abilita il suo stato automatico predefinito. Non sono annunciati NV12 output, HDR, filtri, stereo, interlace, conversione di frequenza o nuovi handle NT/keyed. `NativeVideoProcessorChecks.cpp` verifica sette conversioni sui pixel e il confine delle capacità; si compila con gli stessi include/link nativi indicati sopra. In Windows usa VIDEO_SUPPORT; il runtime può filtrare richieste di stati non annunciati e sintetizzare bit generici NV12 obbligatori: l’enumeratore specifico e le viste restano il gate effettivo. Non interpretare un test nativo come prova browser.

[Prove, negativi e punto di ripresa](../../docs/VERIFICATION.md#2-novembre--processore-video-sdr-reale-e-ponte-hresult).
