# OpenGL protetto — candidate e verifiche

Obiettivo: OpenGL accelerato con kernel ARM64 v0.4 originale Microsoft-signed, Secure Boot/CI attivi e TESTSIGNING disattivato. Stato generale in TODO-014/APP-001 e [report](../../docs/reports/2026-10-28-opengl.md). Non sostituire il pacchetto nel DriverStore o promuovere una candidata dal solo esito di un probe.

**Stato corrente28 ottobre:** scene minime GPU ARM64/x64 e Creality7.3 reale con cubo20mm importato/renderizzato PASS nel clone protetto; nessuna distribuzione main. Rimangono un errore di map23379200byte/0xc000009a e funzioni Vulkan assenti. La scena riuscita non qualifica conformità o affidabilità generale. Kernel originale, Secure Boot/CI attivi e TESTSIGNINGfalse. Clone ripristinato/spento normalmente, main invariata/collegata. [Evidenze](../../docs/VERIFICATION.md#28-ottobre--wgl-zink-e-requisiti-del-backend-mac).

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


## Primo WGL GPU nel clone protetto

Scena minima ARM64 PASS con Zink25.1.9: GL2.1, shader/VBO, due triangoli con profondità24/stencil8, readback, zero erroriGL e pixel della finestra dopo SwapBuffers. Il renderer è AppleM4 tramite Venus/MoltenVK, senza renderer software. Non è una qualifica di conformità GL, affidabilità, prestazioni, x64/Creality o distribuzione main. Rimangono avvisi per logicOp, custom_border_color e depth_clip_enable assenti.

Zink26.1 richiede nullDescriptor che MoltenVK1.4.2 dichiara false. Non rimuovere il controllo o forzare capacità:25.1.9 conserva un vero fallback con risorse dummy. Base ufficiale [Mesa25.1.9](https://archive.mesa3d.org/mesa-25.1.9.tar.xz), SHA256412df33a1bb3c785ed698555a3972118a37c458e7accf6ae53f4bb87b3db454a. È una candidata di compatibilità privata; non è stata promossa a dipendenza dell'app ordinaria.

Patch della prova:

- Su Mesa Neptune bf536bba…: venus-wddm2-shmem.patch, poi venus-win32-blob-order.patch. La seconda attende la sequenza della vera allocazione prima dell'export blob Windows; nessun cambio ai comandi GPU o al kernel. DLL finale ARM64 SHA25617fc7b5c8858407e0e79113757a1a00fa1981522cd96063193af3045b39742e4.
- Su Mesa25.1.9: windows-zink-gdi-present.patch e zink-moltenvk-host-depth.patch. La prima alloca normali target GPU senza swapchain nativa e presenta i pixel completati con GDI; la seconda applica il workaround HOST_TRANSFER già presente per MoltenVK anche quando il driver sottostante è raggiunto tramite Venus. Nessun override di versione o capacità.
- Compatibilità build: windows-clang-atomics.patch e windows-glsl-lexer.patch; risorse DLL del solo zlib statico escluse nella copia privata. Build Gallium con solo zink, nome libgallium_wgl e shim opengl32 distinti, Vulkan vuoto per questa base25.1.9; ICD Vulkan compilato separatamente dalla base Neptune26.1.

Shim ARM64 finale SHA2562c63cded7005e86b8c1f18da63cdfe0017b65693dfa1907576c9b7aae8cc6ef9; Gallium4ef7affbbe10f0ca51e3330b012f5db5ad8df6251f8ea32ace71ab81b96456e7. Binari e ricette fuori Git. La copia CPU per presentare è un compromesso concreto, non zero-copy; costo non misurato.

Il loader standard nel clone ha richiesto manifest con library_path assoluto e reindirizzamento temporaneo delle sole VulkanDriverName PnP con backup. La sola voce globale Khronos non bastava. Nessun file DriverStore sostituito; non riutilizzare questa procedura diagnostica come installer ordinario.

`probe-wgl-triangle.c <DLL> [--present]` fallisce se non vede Apple/Zink, shader/profondità/pixel corretti o se compare un errore GL; --present aggiunge SwapBuffers e lettura dei pixel della finestra sacrificabile. Errori precedenti e perimetro nel [diario](../../docs/VERIFICATION.md#28-ottobre--wgl-zink-e-requisiti-del-backend-mac).


## Verifica x64 e app reale

ICD x64 SHA2565fad25ca4cf9fdf3f6ce95c39a61145eec32f8b64041e3e52bcfecf34004d52d; shim9dbf60f82d58d1ea9bb7439b855a220a91d7b2339a59fe637fdbfbfe791395dd; Gallium0e46e15619106351e3399887206b2ce8186588fe057893c486279ce1356a7aea. Trasferimento Vulkan4096byte e scena WGL shader/profondità/pixel finestra/erroriGL0 PASS in emulazione x64 sul kernel ARM64 firmato.

Creality7.3/EXE6157 verificato da copia privata byte-identica: la stessa app stampa GPU AppleM4/OpenGL2.1, importa STL generato20×20×20mm e lo mostra nel piano3D con12triangoli. Nessuna stampa/slicing o modifica ai documenti dell'utente. Non è ancora una qualifica della main: nell'avvio della finestra grande compare vkMapMemory su23379200byte fallito0xc000009a, pur continuando a renderizzare il modello. Non attribuito alla RAM fisica e nessuna risorsa aumentata per tentativi. Mancano ancora funzioni Vulkan segnalate da Zink; non distribuire come implementazione GL completa.

Il loader elevato ignora VK_DRIVER_FILES/VK_ICD_FILENAMES: la prima prova x64 tentava l'ICD ARM64 PnP e falliva193. Reindirizzamento diagnostico al manifest x64 sufficiente per il PASS; registrazione simultanea delle due architetture e installer ordinario ancora da qualificare. Ripristinate le tre voci originali e rimossa l'esatta voce globale della prova; kernel/ICD/Creality installati con hash invariati. Directory/task della prova rimossi e CD espulso.

Per avviare una GUI persistente non usare Start-Process e poi uscire da execute: il job diagnostico termina anche i figli. La prova applicativa ha usato un task manuale interattivo Limited, con azione in attesa del solo processo e rimosso al termine. Gli errori di preparazione e la pulizia sono nel diario; non erano crash Creality. Il prossimo incremento deve isolare il mapping grande e integrare un percorso ordinario verificabile, senza ripetere i probe già riusciti o forzare capacità/versioni.
