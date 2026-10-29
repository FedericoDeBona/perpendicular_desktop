# OpenGL protetto — candidate e verifiche

Obiettivo: OpenGL accelerato con kernel ARM64 v0.4 originale Microsoft-signed, Secure Boot/CI attivi e TESTSIGNING disattivato. Stato generale in TODO-014/APP-001 e [report](../../docs/reports/2026-10-28-opengl.md). Non sostituire il pacchetto nel DriverStore o promuovere una candidata dal solo esito di un probe.

**Stato corrente28 ottobre —0.2.27 installata sulla VM ordinaria:** shader/profondità/pixel finestra ARM64/x64 PASS da librerie installate; Creality7.3 ordinario dal launcher reale importa e renderizza il cubo20mm anche nella finestra Mac2177×1191. Kernel originale e Secure Boot/CI conservati, TESTSIGNINGfalse. Presentazione GDI con readback suddiviso; funzioni Vulkan mancanti e compatibilità generale ancora aperte. [Evidenze e limiti main](../../docs/VERIFICATION.md#28-ottobre--installazione-opengl-sulla-vm-corrente). I paragrafi successivi conservano le tappe precedenti nel clone.

## Aggiornamento guest locale M4 0.2.32

Il profilo `releases/0.2.32-darwin-arm64-m4.json` ricompila le stesse patch bounded-upload/sampler sulla base locale93be6687, conservando host0.2.27rev2 e le due DLL Vulkan. Il codice correttivo era già versionato, ma le vecchie DLL0.2.27 erano ancora nella VM e nel bundle: pull e build ordinaria riutilizzano il runtime locale, non ricompilano Mesa. Non trasferire il profilo host M1 per correggere questo scarto.

`python3 scripts/package-opengl-guest-update.py --app <build-separata.app> --guest <payload-completo> --release-manifest graphics/opengl/releases/0.2.32-darwin-arm64-m4.json` valida base host e precedente payload per hash, tutti i membri host, sei librerie/architetture e patch; rifiuta una modifica Vulkan. Poi aggiorna solo il payload Guest/OpenGL. Firmare e verificare la build prima della consegna. Il bundle ordinario resta frontend0.2.31 con payload OpenGL0.2.32; il codice frontend è identico, la firma viene rigenerata. Le build successive conservano il payload aggiornato tramite copy-main-runtime.py. Il tool non aggiorna Windows né la main direttamente: nella verifica locale usato l'installer esistente Restore→installazione versionata, con precedente release/backup conservati.

Confronto atlante ARM64/x64 prima FAIL/dopo PASS, MSAA installato PASS e Creality Desktop/cubo20mm/testi leggibili verificati. Nuovo Seamless non ancora verificato; orologio e Shell non corretti da questo incremento. [Evidenze e limiti](../../docs/VERIFICATION.md#29-ottobre--correzione-creality-viola-sulla-base-m4).

## Texture grandi0.2.31

`windows-zink-bounded-upload.patch` evita un singolo mapping CPU dell’atlante RGBA4096×6854 di Creality: il fallback Zink Windows `texture_subdata` suddivide texture2D non compresse/profondità1 in fasce con obiettivo2MiB e attende la conclusione fra le fasce per riusare lo staging. Dimensione, dati, offset e stride della texture restano invariati; niente aumento risorse o capacità artificiali. Non corregge tutti i percorsi map/GetTexImage o texture compresse/array/3D.

Il probe `--atlas` usa gli stessi112295936byte, li rilegge integralmente da FBO per fasce e verifica un disegno con campionamento texture/profondità.0.2.30 fallisce map/contenuto; candidata x64 e ARM64 passano, MSAA4x/resolve conservato. Creality Seamless sulla candidata torna leggibile, magenta GDI1171→0/10005. Profilo riproducibile `releases/0.2.31-darwin-arm64.json`; distribuzione versionata/firma/hash e scena cubo Seamless main verificate. Shell/Settings e prestazioni generali non qualificati. [Diario, limiti e tentativi negativi](../../docs/VERIFICATION.md#28-ottobre--texture-grandi-e-testi-magenta-opengl0231).

## Correzione multisample0.2.30

Su AppleM1 il resolve4x del blitter Gallium generava OpName `sampler`, in conflitto con il tipo Metal del traduttore MoltenVK1.4.2. `zink-moltenvk-sampler-name.patch` su Mesa25.1.9 rinomina solo quel metadato in `zink_sampler`, mantenendo istruzioni e binding. Profilo `releases/0.2.30-darwin-arm64.json`, host/Venus invariati. Probe `--msaa`: fallimento prima, ARM64/x64 PASS dopo; Creality/cubo Desktop e Seamless main PASS nel perimetro della scena, ma glyph e controlli magenta in Seamless mantengono aperta la resa completa. [Diario](../../docs/VERIFICATION.md#28-ottobre--correzione-msaa-opengl0230-e-recupero-cartelle-sulla-iot0795218c).

## Profilo locale AppleM1

`releases/0.2.29-darwin-arm64.json` fissa la coppia Venus/WGC e le sei DLL ricostruite per la base IoT0795218c. Usare `--release-manifest` nel confezionatore; il manifesto predefinito mantiene la base precedente. Main M1: WGL ARM64/x64 PASS, Creality piano3D poi errore shader `sampler`; scena e artefatti ancora IN CORSO. [Evidenze](../../docs/VERIFICATION.md#28-ottobre--opengl0229-sulla-iot0795218c-e-nuovo-errore-shader).

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


## Pacchetto0.2.27 e ripristino

`release.json` fissa sorgenti, patch, sei DLL, tre input host e l’hook WGC già esistente della release. `scripts/package-opengl.py` inserisce renderer/server abbinati e MoltenVK in una build separata, dopo aver verificato la base qualificata e gli hash; firma i nuovi MachO e preserva QEMU/DXMT. Dopo il confezionamento serve firmare/verificare il bundle completo. `NativeGraphics` ammette `venus_version=1` soltanto con backend presente nel manifesto verificato; la sola primaria3D attiva Venus. Il sorgente host deve includere `host-wgc-export.patch` e una copia byte-identica di `graphics/renderer/wgc-export.inc` in `src/neptune/perp-wgc-export.inc`, oltre alla configurazione Venus/Neptune. Il confezionatore rifiuta renderer/server privi di questo hook se richiesto dalla base: la prima coppia Venus senza hook superava OpenGL ma interrompeva le finestre Seamless. Nessun cambiamento delle risorse VM. La build ordinaria successiva conserva sia il runtime sia `Resources/Guest/OpenGL` dalla app di riferimento qualificata; non riconfezionare questa release contro una base diversa senza aggiornare i pin.

La revisione host2 ripristina anche `graphics/renderer/initial-capture-decline.patch`, su entrambi i componenti della coppia. La prima build Venus dichiarava questa capacità nel manifesto ereditato, ma ne ometteva il codice: un produttore multi-ring non può essere acquisito dal percorso nativo corrente. Il rifiuto iniziale deve lasciare continuare il rendering e gli altri contesti, mantenendo il divieto di leggere superfici prive di ordinamento verificato. Il confezionatore ora rifiuta anche la libreria priva di questa gestione; i pin fissano il worker abbinato. Le sei librerie OpenGL guest restano0.2.27. Questo ripristino non corregge per sé le etichette mancanti nella Shell Windows.

L'installer `install.ps1` va eseguito in Windows con il controllo della UUID attesa, payload completo e percorso assoluto dell'eseguibile da abilitare. Sono qualificati ARM64 e x64; altre architetture sono rifiutate. Richiede Secure Boot/CI attivi e test signing disattivato, hash del kernel/ICD originali e applicazione chiusa. Conserva lo stato in `C:\ProgramData\Perpendicular\Graphics\OpenGL`, scrivibile soltanto da amministratori/SYSTEM; le applicazioni ordinarie hanno lettura/esecuzione. Crea manifest assoluti di entrambe le architetture e modifica soltanto le registrazioni PnP originali riconosciute. Il [loader Khronos documenta REG_MULTI_SZ](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md) per l'elenco dei manifest VulkanDriverName; la DLL con architettura incompatibile viene scartata. Non servono variabili Vulkan elevate ignorate dal loader.

Le due librerie OpenGL corrispondenti all'architettura vengono copiate accanto all'eseguibile scelto, con backup dell'eventuale coppia precedente. **Questo abilita l'applicazione selezionata: non è una registrazione ICD OpenGL globale per tutti i programmi.** La distribuzione corrente abilita Creality Print7.3 ordinario. La registrazione Vulkan rimane disponibile per entrambe le architetture. Nessuna modifica all'eseguibile dell'app, al kernel, al DriverStore o alle protezioni.

Per annullare usare lo stesso installer con UUID attesa e `-Restore`, ad applicazione chiusa. Il ripristino controlla che chiavi/file non siano cambiati esternamente, ricrea tipi/valori originali e ripristina o elimina soltanto le due DLL registrate nel backup. Conserva lo storico `restored-*.json` e la release protetta. Installazione→ripristino→audit→reinstallazione verificati sulla VM ordinaria. L'aggiornamento di una release già attiva è deliberatamente rifiutato: prima ripristinare o qualificare esplicitamente una migrazione.

`windows-zink-bounded-readback.patch`, dopo windows-zink-gdi-present.patch, suddivide la lettura per presentazione in fasce con obiettivo2MiB in base ai byte per riga (minimo una riga). Presenta il bitmap CPU soltanto se tutte le fasce sono riuscite. Non aumenta RAM/apertura GPU e non disattiva errori o sincronizzazione. Non è zero-copy né una soluzione per qualsiasi allocazione grande dell'app; l'errore storico e il perimetro della verifica corrente restano nel diario.
