# Video browser nel Desktop Windows

Obiettivo: ridurre i frame persi nei video 4K conservando immagini, input e protezioni. I contatori YouTube/browser non misurano direttamente gli scarti del presenter Mac.

## Diagnostica minima del driver

`guest/examples/video_capabilities.rs` crea esclusivamente un device hardware D3D11, identifica l'adattatore e interroga `ID3D11VideoDevice`/profili decoder. Non cambia impostazioni e non installa componenti. L'assenza dell'interfaccia è un risultato diagnostico, non un errore del programma. Un'interfaccia presente non prova che un codec o il browser funzionino in hardware.

Dal Mac, con toolchain e SDK già predisposti come in `scripts/build-guest.sh` e dipendenze fissate da `guest/Cargo.lock`:

```sh
export PATH="$HOME/.local/share/perpendicular-build-tools/bin:$HOME/.cargo/bin:$PATH"
export XWIN_ARCH=aarch64
export XWIN_CACHE_DIR="$HOME/.local/share/perpendicular-build-tools/windows-sdk"
export RUSTFLAGS='-C target-feature=+crt-static'
cargo-xwin build --manifest-path guest/Cargo.toml --example video_capabilities --release --target aarch64-pc-windows-msvc --locked
```

Eseguire `guest/target/aarch64-pc-windows-msvc/release/examples/video_capabilities.exe` dentro Windows, con trasporto temporaneo e pulizia del supporto; non includere VM/ISO/eseguibili generati in Git. Il controllo deve usare il runtime realmente avviato, confrontato con il bundle canonico e con i driver guest, prima di attribuire una capacità mancante a una nuova regressione.

## Risultato qualificato 1 novembre, M1/0.2.59

```json
{"adapter":"Red Hat VirtIO GPU 3D controller","deviceID":4176,"featureLevel":"0xb000","vendorID":6900,"videoDevice":false,"videoDeviceHRESULT":"0x80004002"}
```

`E_NOINTERFACE` sul device hardware Neptune/Wire2 effettivo; nessun fallback WARP. Edge ha compositing GPU attivo, ma nessun profilo di decodifica hardware; il video VP9 3840×2160 usa `VpxVideoDecoder`, `kIsPlatformVideoDecoder=false`. L'etichetta generica `video_decode=enabled` non prova la disponibilità di un decoder. L'interrogazione dell'interfaccia segue la [documentazione Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nn-d3d11-id3d11videodevice).

Baseline reale:311/1584frame persi (~19,6%). Forzare il solo raster GPU (`enabled_force` verificato nel profilo QA isolato) non ha fornito un miglioramento:469/989 (~47,4%); candidato respinto e rimosso. Le finestre temporali non sono identiche e includono stalli: non quantificare da questi soli valori un rapporto causale di peggioramento.

Per riprendere: prima un frame reale decodificato attraverso una minima integrazione UMD/host compatibile con Secure Boot/CI, poi collegamento al browser e breve confronto stesso codec/contenuto/risoluzione. Non annunciare accelerazione perché compare un GUID o perché si abilita un flag. I precedenti esperimenti di pacing e sincronizzazione respinti restano tali; gli artefatti scroll richiedono evidenza distinta.

[Evidenze, tentativi falliti e limiti](../../docs/VERIFICATION.md#1-novembre--desktop-mode-edge-e-youtube4k), [PERF-002](../../docs/KNOWN_ISSUES.md#perf-002--frame-persi-nei-video-4k-in-desktop-mode).

## Primo frame VP9 host, prima del ponte Windows

Il M1 effettivo supporta VP9 hardware **dopo** la chiamata per processo a `VTRegisterSupplementalVideoDecoderIfAvailable`. La query prima della registrazione restituisceva false; non usarla come prova di impossibilità. Il prototipo `scripts/probe-native-video.swift` richiede hardware, decodifica il primo keyframe di un IVF profile0/8bit/4:2:0 fino a4096×2160, verifica NV12 e crea le due texture Metal. È un controllo di fattibilità, non un decoder Windows installabile. Non espone profili fittizi né cambia runtime/app.

Con FFmpeg già installato e Xcode, scegliere una directory privata nuova per tutti gli output (non sovrascrivere file):

```sh
video_qa_dir="$(mktemp -d "${TMPDIR%/}/perpendicular-video.XXXXXX")"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=3840x2160:rate=60' -frames:v 1 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -f ivf "$video_qa_dir/frame.ivf"
xcrun swiftc -O -warnings-as-errors scripts/probe-native-video.swift -o "$video_qa_dir/probe"
"$video_qa_dir/probe" "$video_qa_dir/frame.ivf"
ffmpeg -hide_banner -loglevel error -i "$video_qa_dir/frame.ivf" -frames:v 1 -pix_fmt nv12 -f hash -hash sha256 -
```

Confrontare il digest del riferimento con `nv12SHA256`, non solo l'exit code. Verifica locale1novembre: hardwaretrue,3840×2160,2plane Metal,12.441.600byte; hash esatti. Il primo decode+wait10,11ms esclude setup e non misura FPS sostenuti. Vedere il diario per fallimento iniziale-12906 senza registrazione e limiti.

Il lavoro successivo deve preservare la coppia Wire2 e le patch già distribuite, aggiungere supporto reale NV12/plane, decoder e gestione vita/completamento nel backend appropriato. La presenza dei messaggi video nel protocollo non implementa queste capacità. Nessuna accelerazione YouTube è ancora distribuita e Creality3D resta la seconda priorità richiesta.


## Diagnostica ripetibile e registrazione della candidata

`observe-video.ps1` osserva un endpoint Edge loopback già aperto (default9222)
e la pagina YouTube di prova esistente. Sottoscrive Media, legge SystemInfo e
contatori del video senza navigare o modificare play/qualità/flag. Parametri:
`-SampleCount 30 -Port 9222`; conservare output JSON fuori Git. Il tempo campione
è misurato con Stopwatch; massimo2000eventi Media, con conteggio esplicito degli
eventi omessi. Escludere confronti che mescolano decoder/codec/risoluzione o pause;
i contatori browser non misurano direttamente gli scarti del presenter Mac.
Avviare Edge con profilo QA separato, raccogliere gli eventi mentre si sceglie la
qualità dalla UI e distinguere replay di errori passati da nuovi crash nel campione.

`install-video-candidate.ps1` registra soltanto la libreria user-mode sperimentale
in una directory Program Files nuova. Richiede consenso amministrativo ordinario,
UUID atteso, SHA256 candidato e PrivateBuild atteso come parametri obbligatori;
`PayloadRoot` contiene `neptune_umd_arm64.dll`. Verifica kernel e quattro UMD
originali, ABI100.6.101.58000, SecureBoot/CI/TestSigning, conserva wrapper/companion
originali e backup dei soli UserModeDriverName modificati. DriverStore/WoW/Vulkan
restano invariati. Non è il bootstrap universale del prodotto e non qualifica
una candidata: usarlo su copia isolata con host/protocollo allineati e verificare
i moduli effettivi dopo avvio completo, poi pixel e browser. Una precedente
registrazione QA va ripristinata dal suo backup verificato prima della nuova
installazione; non sovrascrivere o cancellare le directory precedenti.

L'esito M4 del2novembre distingue tre frame Windows hardware corretti dalla
successiva disconnessione Edge: il log correla E_NOTIMPL del processore video
DirectComposition e uscita GPU34. La candidata aggiunge elaborazione SDRprogressiva
reale e inoltro DDI, da qualificare prima della main; non equivale a un flag che
forza il rendering. [Evidenze](../../docs/VERIFICATION.md#2-novembre--primo-edge-m4-e-disconnessione-nella-presentazione-directcomposition).
