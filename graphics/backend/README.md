# Backend grafico corrente

Il backend effettivo va identificato dal `runtime.json` e dai byte della libreria nel runtime usato dal processo QEMU corrente, poi confrontato con le correzioni condivise secondo [AGENTS.md](../../AGENTS.md). Il solo bundle canonico, la versione del frontend o il vecchio riferimento `3fff2d025a3f` non identificano tutte le macchine: sulla base M4 verificata il29ottobre è caricato `0bf5a8192263…`. Le patch e i preparatori di questa directory hanno basi precise; non costituiscono una build universale della combinazione attuale. Conservare l'abbinamento Wire2 identificato nel [piano](../../docs/RESTART_PLAN.md).

`named-errors.patch` aggiunge il nome dell’operazione a cinque messaggi generici, mantenendo risultato e frequenza del logger. Un messaggio nominato non dimostra da solo la causa di un difetto visivo.

`shared-initialization.patch` invia le inizializzazioni pendenti e attende il relativo evento GPU prima di esportare il descrittore di una texture condivisa. Al timeout di 1000 ms restituisce E_FAIL con handle nullo. Non sostituisce la sincronizzazione fra writer successivi e non modifica driver o protocollo guest. `tests/NativeSharedTextureChecks.cpp` verifica questo specifico confine con due device nativi; non qualifica tutti gli ordinamenti fra processi o la cattura Windows.

`native-bounded-capture.patch` resta diagnostica opzionale, non abilitata per l’uso corrente. Può catturare un solo worker selezionato con un marker privato; richiede un avvio diagnostico e può registrare pixel delle app. Non riattivarla o ricompilare il backend senza una domanda concreta pertinente al desktop.

`rebuild-native-backend.py` conserva input della vecchia base Wire1; non usarlo per sostituire automaticamente il runtime corrente. `rebuild-native-shared-initialization.py` richiede il proprio riferimento e runtime Wire2 pinned. Ogni output nuovo conserva una ricevuta, ma build e firma non dimostrano il funzionamento in Windows. Verificare gli input disponibili, preservare la coppia renderer/server e qualificare il passaggio modificato in una nuova copia privata.

Le vecchie istruzioni di cattura, i comandi di build legati a profili storici e i tentativi intermedi sono tolti dalla guida corrente. Restano nel [diario delle verifiche](../../docs/VERIFICATION.md) e nella [versione storica](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/graphics/backend/README.md).

## Candidata NV12 nativa, non distribuita

`nv12-native.patch` è il prerequisite per il decoder VP9: due texture Metal per un'immagine NV12, SRV di piano e trasferimenti coerenti. Deriva dalla [proposta di hadykachmarv-coder](https://github.com/3Shain/dxmt/issues/229), [gist](https://gist.github.com/hadykachmarv-coder/b8a3074182aa755f6bedde534481855e) revisione `822a74043048972717460b51688e23f739bebc1a`, adattata al nostro pin e alle sue firme/gestione BC. Le modifiche ereditano la licenza dei sorgenti DXMT (LGPL2.1-or-later); attribuzione e fallimenti conservati nel diario. La parte swapchain desktop della proposta non è inclusa.

La build ordinaria continua a usare il backend qualificato: questa candidata non implementa ancora VideoDevice/Context, decodifica Windows o condivisione NV12 fra processi. Non esporre profili codec o cambiare la main in base al solo PASS nativo. I pin della ricetta sono in [video-inputs.json](video-inputs.json), non sostituiscono quelli del runtime di produzione.

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
