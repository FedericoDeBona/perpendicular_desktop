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
