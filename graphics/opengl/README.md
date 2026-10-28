# OpenGL protetto — candidate e verifiche

Obiettivo: OpenGL accelerato con kernel ARM64 v0.4 originale Microsoft-signed, Secure Boot/CI attivi e TESTSIGNING disattivato. Stato generale in TODO-014/APP-001 e [report](../../docs/reports/2026-10-28-opengl.md). Non sostituire il pacchetto nel DriverStore o promuovere una candidata dal solo esito di un probe.

## Memoria Vulkan WDDM2

`venus-wddm2-shmem.patch` si applica a [Mesa Neptune bf536bba65454900d782fa7417bc95c1608d7483](https://github.com/osy/virtio-win-mesa/tree/bf536bba65454900d782fa7417bc95c1608d7483). Per il percorso standalone WDDM2 usa l'identità di allocazione con cookie e la finestra CPU restituita da RES_INFO, come il transport Neptune della stessa base. La finestra viene distrutta dal KMD, senza Lock/Unlock o MAP_BLOB legacy. Le attese della vita dell'allocazione seguono il percorso nativo; non sono disattivate le sincronizzazioni dei comandi Vulkan. Gli altri percorsi mantengono la gestione precedente.

La modifica è limitata a una DLL user-mode separata. Non modifica KMD, INF/CAT, firmware, Code Integrity, protocollo host o DLL ufficiale installata. `windows-clang-atomics.patch` corregge i nomi delle intrinseche nella stessa base Mesa per la compilazione clang-cl; non è una modifica alla sincronizzazione del driver.

Prima candidata ARM64 privata: SHA256 `6c645c6e306a2da46ea2620f1258ddd9206890031e51bbf71e4f235737f85c98`. Nel clone protetto: originale fallisce allocate/map ring, candidata crea l'istanza ed enumera una GPU; buffer GPU 4096byte scritto/riletto PASS. Nessuna qualifica generale di import/export, WSI, prestazioni, x64 o scena OpenGL. Non aggiungere modifiche al submit virtuale senza una necessità misurata: il trasferimento minimo usa già il percorso esistente con successo.

Build privata verificata con Windows SDK/CRT ARM64 10.0.26100 tramite xwin e header WDK ARM64 10.0.26100.6584. Meson: `vulkan-drivers=virtio`, `gallium-drivers=`, `neptune=false`, `platforms=windows`, `glx/egl/llvm/zstd/xmlconfig/glvnd=disabled`, `default_library=static`, `b_vscrt=mt`. Per la build cross su macOS sono stati necessari adattatori locali per i percorsi clang-cl/linker e i metadati del solo zlib statico; ricette, sorgenti degli adattatori e hash degli input restano nelle evidenze private citate nel diario. Non è ancora un nuovo percorso della build ordinaria dell'app.

## Probe circoscritti

- `probe.ps1`: WGL, disponibilità D3D12/Vulkan e stato Secure Boot; nessuna installazione.
- `probe-host-vulkan.c`: GPU ed estensioni contro una libreria Vulkan host esplicita.
- `probe-icd.ps1 -IcdPath <DLL>`: separa il caricamento dell'ICD dall'inizializzazione; logging limitato al processo.
- `probe-vulkan-buffer.c <DLL>`: un solo trasferimento GPU con lettura dei4096byte, tramite ICD esplicito e GPU hardware. Non qualifica WSI o OpenGL.

Output, DLL, ISO, log e dischi di prova vanno fuori Git. Le prove nel clone non sostituiscono la verifica di una scena nell'app principale. [Diario](../../docs/VERIFICATION.md#28-ottobre--memoria-venus-wddm2-e-primo-trasferimento-gpu-protetto).
