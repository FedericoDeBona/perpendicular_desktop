# Driver grafico corrente

La base desktop usa il driver ufficiale ARM64 v0.4 firmato Microsoft, identificato in [guest/graphics-driver.json](../../guest/graphics-driver.json). Nel sistema di sviluppo: VioGpu3D Running, SYS cfbc713754c7, Secure Boot attivo e TESTSIGNING disattivato.

Il [resize personalizzato](custom-resolution.md) ora funziona attraverso la sequenza host dell’app; non richiede una modifica del KMD. L’app conserva la cornice Mac e conferma la risoluzione Windows effettiva dopo la notifica monitor. [Prova reale](../../docs/VERIFICATION.md#25-ottobre--resize-con-driver-ufficiale-e-protezioni-ripristinate).

Le candidate test-signed di scheduler, completamento, compositore e resize KMD sono ritirate dal ramo attivo su richiesta dell’utente. La prova del compositore aveva provocato arresti: nessuna promozione o correzione causale dichiarata. Patch e controlli sintetici sono recuperabili dalla [revisione precedente](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/graphics/driver); esiti negativi e limiti rimangono nel diario e nel [registro dei problemi](../../docs/KNOWN_ISSUES.md). Il vecchio clone Driver Trial è stato eliminato nella pulizia autorizzata: non usare i relativi helper o percorsi come configurazione operativa.

Non riattivare modalità test o candidate DWM per il normale resize. Per un nuovo intervento partire da un difetto concreto nelle app e mantenere driver, UMD/helper e runtime compatibili. [Piano corrente](../../docs/RESTART_PLAN.md), [indice delle prove ritirate](../../docs/RETIRED_EXPERIMENTS.md).

## Candidata Win32 SIZE_T (3 novembre, non promossa)

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

La build ordinaria continua a usare la distribuzione qualificata precedente.
Questa candidata resta privata finché gioco hardware, input e fluidità non
sono verificati nella copia e poi nella main. Alla promozione occorrono payload
versionato e controllo build che rifiuti le librerie prive del fix; non copiare
silenziosamente un output locale. [Stato/evidenze](../../docs/VERIFICATION.md#3-novembre--lok-hardware-dopo-il-riscontro-sulla-fluidita).
