# Driver grafico corrente

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
