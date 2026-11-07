# Driver grafico corrente

**Candidata .93 (7 novembre):** percorso host senza unplug implementato e compilato; driver upstream firmato v0.5 aggiunge i nuovi modi al monitor esistente e normalizza EDID. [Pin/ricetta/patch](../../graphics/driver/connected-resize-v05.json) e [verifica in corso](../../docs/VERIFICATION.md#driver-firmato-v05-e-modi-a-monitor-collegato). Installazione/coldboot QA, integrazione installer ordinari e qualifica main ancora pendenti; non equivale a correzione verificata di icone/nero o prestazioni.

La base desktop usa il driver ufficiale ARM64 v0.4 firmato Microsoft, identificato in [guest/graphics-driver.json](../../guest/graphics-driver.json). Nel sistema di sviluppo: VioGpu3D Running, SYS cfbc713754c7, Secure Boot attivo e TESTSIGNING disattivato.

**Nuovo requisito del7 novembre:** il [resize personalizzato](custom-resolution.md) deve mantenere il monitor collegato, senza unplug o successivo recupero delle finestre. Intervenire su driver/notifiche e sul riconoscimento/applicazione dei nuovi modi; conservare protezioni e compatibilità dei componenti. La sequenza host con scollegamento è una base storica installata, non soddisfa il nuovo criterio e non va sviluppata come soluzione definitiva. [Obiettivo e prove precedenti](../../docs/VERIFICATION.md#cambio-obbligatorio-di-percorso-resize-a-monitor-collegato).

Le candidate test-signed di scheduler, completamento, compositore e resize KMD sono ritirate dal ramo attivo su richiesta dell’utente. La prova del compositore aveva provocato arresti: nessuna promozione o correzione causale dichiarata. Patch e controlli sintetici sono recuperabili dalla [revisione precedente](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/graphics/driver); esiti negativi e limiti rimangono nel diario e nel [registro dei problemi](../../docs/KNOWN_ISSUES.md). Il vecchio clone Driver Trial è stato eliminato nella pulizia autorizzata: non usare i relativi helper o percorsi come configurazione operativa.

Non riattivare modalità test o candidate DWM per il normale resize. Per un nuovo intervento partire da un difetto concreto nelle app e mantenere driver, UMD/helper e runtime compatibili. [Piano corrente](../../docs/RESTART_PLAN.md), [indice delle prove ritirate](../../docs/RETIRED_EXPERIMENTS.md).

## Correzione Win32 SIZE_T 0.1.0 (3 novembre)

LOK è un player Unity x86. Il codec originale tratta i puntatori `SIZE_T *`
Windows32 come `uint64_t *`: il controllo Windows reale legge byte adiacenti
e sovrascrive i canary in decodifica. [Patch](x86-size-t-wire.patch): conversione
esplicita per valore, stride nativo degli array, wire64 conservato e rifiuto
dei valori non rappresentabili. Il controllo [check-size-t-wire.c](check-size-t-wire.c)
compilato Win32 contro gli header originali fallisce quattro condizioni;
contro quelli corretti passa scalare/array/canary/overflow. Non è prova di FPS.

[rebuild-x86-umd.py](../../scripts/rebuild-x86-umd.py) ricostruisce una directory
nuova esterna al repository da [input verificati](x86-umd-inputs.json). Richiede
gli archivi Mesa/WDK/LLVM già appuntati, clang-cl/lld-link/llvm-lib e SDK/CRT
Microsoft Win32 (10.0.26100/14.44.17.14), Meson/Mako/PyYAML appuntati e Ninja.
Le librerie x86 si preparano con cargo-xwin0.23.1, `XWIN_ARCH=x86`, target
`i686-pc-windows-msvc`; conservare il SDK preparato prima di cambiare architettura
della cache. Il builder rifiuta hash/versioni differenti. Riutilizza la patch
atomiche Clang già condivisa per OpenGL, senza introdurre la candidata video ARM64.

```sh
python3 scripts/rebuild-x86-umd.py \
  --mesa-archive "$mesa_archive" --wdk-archive "$wdk_archive" \
  --llvm-archive "$llvm_archive" --windows-sdk "$compiler_tools" \
  --x86-sdk "$x86_sdk" --meson "$meson" --ninja "$ninja" \
  --output "$fresh_external_output"
```

Output: `build/src/virtio/neptune/triton/neptune_umd.dll`, PE32 i386 con ABI
100.6.101.58000. Rinominare soltanto la copia del payload `neptune_umd_x86.dll`.
[Installer sperimentale](install-x86-candidate.ps1) con normale consenso
amministratore, UUID/hash obbligatori, Secure Boot/CI originali: directory
protetta in Program Files e sole registrazioni `UserModeDriverNameWoW` già
riconosciute. DriverStore/kernel/ARM64/Vulkan/OpenGL conservati; backup e `-Restore`
verificano che i valori appartengano ancora alla candidata prima di ripristinarli.
Non basta un valore di registro: confermare il modulo caricato dal processo.

La copia LOK carica la nuova DLL dopo cold boot: menu, livello1-1 e clic sulle
tessere verificati; l'utente conferma «va molto meglio». È una verifica della
fluidità d'uso, senza una misura FPS numerica. La VM principale non ha ancora
ricevuto la registrazione Windows; il bundle canonico contiene il payload per
il normale aggiornamento dei componenti guest. [Stato/evidenze](../../docs/VERIFICATION.md#3-novembre--lok-hardware-dopo-il-riscontro-sulla-fluidita).

L'autorità condivisa è [x86-requirements.json](x86-requirements.json); la
[release0.1.0](releases/x86-0.1.0.json) vincola DLL/installer per hash.
`scripts/check-x86-payload.py` rifiuta payload mancanti, obsoleti, alterati o
con ABI/wire incompatibili prima della compilazione e durante la copia del runtime.
Una nuova release può soddisfare gli stessi requisiti; non modificare i pin
per far passare un componente privo della correzione.

Su un altro Mac conservare il relativo backend host/OpenGL. Ricostruire il solo
componente Windows32 compatibile con la ricetta, quindi confezionarlo in una
copia separata dell'app:

```sh
python3 scripts/package-x86-payload.py --app "$separate_app" \
  --umd "$fresh_external_output/build/src/virtio/neptune/triton/neptune_umd.dll" \
  --release-manifest graphics/driver/releases/x86-0.1.0.json
codesign --force --sign - "$separate_app"
PERPENDICULAR_RUNTIME_APP="$separate_app" zsh scripts/build-macos.sh
```

Il normale installer guest applica il payload presente nel bundle. Riapplicare
la stessa release verifica hash/backup/registro e restituisce `already-installed`
senza sovrascrivere; una registrazione diversa viene preservata e rifiutata.
Dopo la prima installazione serve spegnimento/avvio completo di Windows e
conferma del modulo effettivo: il primo processo prima del reboot usava ancora
la vecchia DLL. Sorgenti/patch/ricette sono in Git, DLL/dischi/SDK restano fuori.

### Profilo M4 e release Win32 0.1.1

Il builder accetta `--toolchain-profile m4-clang-2100.3.34.2-llvm15`,
con gli stessi archivi, SDK Win32, patch e ABI della release0.1.0. Il profilo
vincola Apple clang2100.3.34.2 e `lld`/`llvm-ar`15.0.7 estratti dall’archivio
LLVM già fissato, senza cambiare i pin originali o il backend host del Mac.
La [release0.1.1](releases/x86-0.1.1.json) fissa il relativo output Windows32.
Il normale packager può ricevere questo manifesto tramite `--release-manifest`.

Nel Windows principale M4, dopo arresto/avvio normale, codec SIZE_T32
scalare/array/canary/overflow e CreateInputLayout→draw→readback su VirtIO
hardware passano; modulo effettivo `x86-6cf6a7915f20` confermato. Sono prove
di correttezza e distribuzione. La prima sessione LOK sul Desktop lagga perché
il log identifica WARP; riaperto lo stesso exe senza `-force-driver-type-warp`,
carica la nuova UMD/VirtIO e l’utente conferma «Ora è fluido». Il vecchio
collegamento software è stato conservato e aggiornato a `-force-d3d11`, senza
forzare risoluzione. Non è una misura FPS. [Evidenze e limiti](../../docs/VERIFICATION.md#3-novembre--pull-rebuild-e-guest-tools-sul-m4).

## Candidata resize connesso v0.5 (.93, M1)

Il driver originale firmato v0.5 aggiunge i modi al monitor già presente,
conservando il wire2 e gli header KMD/UMD della base. Pin e differenza upstream
sono in [connected-resize-v05.json](connected-resize-v05.json) e
[upstream-connected-modes.patch](upstream-connected-modes.patch). Il profilo
candidato conserva UMDv19, x86 M1 e OpenGL0.2.34: non sostituire queste librerie
con quelle nuove dell'archivio. Altri profili richiedono una qualifica esplicita.

```sh
python3 scripts/prepare-connected-resize.py --output "$fresh_external_media"
python3 scripts/package-connected-resize.py --app "$separate_runtime_reference" \
  --payload "$fresh_external_media" --sign
python3 scripts/check-connected-resize.py --app "$separate_runtime_reference"
PERPENDICULAR_RUNTIME_APP="$separate_runtime_reference" zsh scripts/build-macos.sh
```

Usare una copia separata dei componenti canonici compatibili. Un riferimento
senza `Contents/MacOS`, senza `CFBundleExecutable` e tipo `BNDL` non può avviare un frontend; usare un ID componente `com.perpendicular.restart.*` e `--sign` per la firma persistente di questo Mac. Il controllo build rifiuta
un bundle privo del pacchetto firmato o con installer/ABI/profilo diversi;
non forzare pin per riusare la vecchia base. Il pacchetto copia soltanto i
componenti pubblici fissati, mai configurazioni/credenziali dei media privati.

L'installer candidato richiede normale amministrazione e identifica una sola
PCI accelerata1101. Conserva e rilegge registrazioni video/x86/Vulkan qualificate;
non aggiorna le uscite app con quel driver. Dopo installazione serve spegnimento
normale e coldboot: la ricevuta non prova pixel o caricamento della nuova coppia.
L'installer guest ordinario video/x86 è ancora vincolato al kernel precedente:
**integrazione degli aggiornamenti ripetibili e consegna main DA FARE**. Non
promuovere questa candidata come aggiornamento ordinario prima di completarle.

QA protetta: coldboot e primo percorso sempre collegato PASS circoscritto,
1440×1676→2880×1800→ritorno e2880×1676→fullscreen→ritorno con nuovi frame/DPI96.
Icone Settings nel Desktop, input postcicli, avvio iniziale/regressioni e main
restano aperti. [Evidenze e negativi](../../docs/VERIFICATION.md#driver-firmato-v05-e-modi-a-monitor-collegato).
