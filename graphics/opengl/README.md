# OpenGL protetto — candidate e verifiche

Obiettivo: OpenGL accelerato con kernel ARM64 v0.4 originale Microsoft-signed, Secure Boot/CI attivi e TESTSIGNING disattivato. Stato generale in TODO-014/APP-001 e [report](../../docs/reports/2026-10-28-opengl.md). Non sostituire il pacchetto nel DriverStore o promuovere una candidata dal solo esito di un probe.

**Regola permanente tra macchine:** i fix necessari sono dichiarati in `requirements.json`, indipendentemente dal numero della release locale. `scripts/check-opengl-payload.py --app <bundle>` controlla le patch richieste contro i sorgenti e tutti i sei hash DLL. La build ordinaria lo esegue prima della compilazione/copia e sul risultato finale, incluso SKIP_RUNTIME; anche copy-main-runtime.py rifiuta un riferimento obsoleto prima di scrivere la destinazione. Allo scarto va completata la distribuzione della ricetta compatibile esistente, prima di riaprire la diagnosi del bug. La verifica delle DLL e del runtime effettivamente usati in Windows resta obbligatoria per la consegna: un bundle corretto da solo non la sostituisce. Per ogni nuovo fix binario aggiornare patch/ricetta/pin e questo contratto, così l'altra macchina ne rileva la mancanza. Le release M1 0.2.31 e M4 0.2.32 erano allineate prima del requisito readback del3novembre; il nuovo profilo M1 è0.2.33. Non occorre uniformare indiscriminatamente i runtime host.

## Batch e riuso di produzione 0.2.34 — compilato, distribuzione da completare

Il 4 novembre l'utente conferma la navigazione utilizzabile nella copia con la candidata batch/cache9118. Il nuovo `windows-zink-cached-batch-readback.patch`, applicato dopo il cache seriale .33, conserva la stessa logica senza timing/controllo file: copia le fasce corrette in una sola submission/attesa e riusa massimo16buffercoerenti/32MiB con singoli mapping≤2MiB. Risorse occupate usano buffer temporanei; casi oltre i limiti/formati non coperti usano il seriale .33. Default attivo, optout di processo `PERP_WGL_BATCH_READBACK=false`; nessun cambiamento a kernel, protezioni o protocollohost.

Ricetta: aggiungere `--batch-readback` al comando `build-wgl-readback-cache.py` riportato sotto. Il profilo `releases/0.2.34-darwin-arm64-m1.json` contiene pin delle due DLL compilate e quattroshim/ICD invariati, basi immediate host/release. La verifica runtime dei binari di produzione e distribuzione main sono ancora pendenti: il riscontro positivo riguarda la candidata funzionalmente equivalente. Payload/backup privati conservati. Il gate richiede già questa correzione e rifiuta .33; sulla macchina locale confezionare/qualificare .34 con `package-opengl-guest-update.py`, sull'altro Mac ricompilare dal suo profilo/toolchain compatibile senza forzare hash o trasferire il runtimeM1. Non presentare il solo gate o la build come prova di fluidità.

## Riuso readback Windows0.2.33 — distribuito, navigazione in verifica

`windows-zink-readback-cache.patch` conserva nel context un solo buffer coerente
di staging, massimo2MiB, per letture color2D Windows64bit. Riusa memoria e mapping
quando il buffer non appartiene ad altri transfer, mantenendo copia e fence per
ogni fascia. Formati non coperti, buffer occupato o memoria non coerente seguono
il percorso precedente. Alla distruzione context il mapping viene rilasciato
dopo l'attesa GPU già esistente. Nessuna variazione a risoluzione, dimensioni
texture, capacità, kernel o protocollo host. `PERP_ZINK_REUSE_READBACK=false`
nel solo processo permette il confronto diagnostico; il valore predefinito è
attivo. Non include timing o il batch errato descritto sotto.

Confronto fresco Creality/cubo20 e viewport1488×1107, stessoDLL diagnostico:
mediana316ms disattivato contro69ms attivo (~4,56volte meno tempo nel percorso
WGL). Non sono FPS continui sul Mac. Build di produzione ARM64/x64, pixel finestra,
MSAA e confronto integrale dell'atlante112295936byte PASS nella copia. Installazione,
restore e reinstallazione0.2.33 PASS nella copia. Installazione main e audit completo PASS; librerie effettive Creality e riuso confermati. Main: cubo/testi/cambio orientamento e zoom corretti senza trace. Navigazione continua e pan ancora da qualificare; nessun FPS generale rivendicato.

Ricostruzione incrementale dalla cache Mesa25.1.9 qualificata di questa macchina:

```sh
python3 scripts/build-wgl-readback-cache.py --cache /private/path/mesa-cache --output /private/path/new-wgl-output --meson /private/path/venv/bin/meson --ninja /private/path/venv/bin/ninja --base-release graphics/opengl/releases/0.2.31-darwin-arm64.json
```

La ricetta verifica sorgenti, entrambe le DLL precedenti e Meson1.12.1; prende lo
stesso lock della diagnostica, conserva backup/ricevuta, compila con due job e
ripristina la cache qualificata anche su errore. Richiede la toolchain Windows
già configurata per ciascuna architettura. Su M4 usare il relativo manifesto base
0.2.32 e toolchain compatibile; produrre pin locali, senza copiare il runtime M1
o forzare gli hash. Il profilo nuovo M4 non è ancora qualificato.

Per confezionare, copiare il payload precedente completo in un nuovo output e
sostituire solo le due libgallium con gli output della ricetta. Il profilo M1
`releases/0.2.33-darwin-arm64-m1.json` fissa seiDLL e patch, oltre agli hash di
manifesto host e release precedenti. Usare `package-opengl-guest-update.py` su
una build separata, firmare e verificare. Il requisito condiviso ora rifiuta i
vecchi payload. Host/video/Venus/shim restano byte-identici.

In Windows, ad app chiusa e con UUID verificata, usare l'installer esistente in
due processi PowerShell separati: prima `install.ps1 -ExpectedMachineID <UUID>
-Restore`, poi `install.ps1 -ExpectedMachineID <UUID> -PayloadRoot <nuovo-payload>
-ApplicationExecutable <exe>`. Richiedono normale elevazione. Conservare payload
precedente/backup e verificare install-state, seiDLL, registrazioni e moduli
effettivi. Per rollback: restore nuovo e reinstallare il payload precedente,
sempre con gli stessi controlli. Le sole sidecar diagnostiche private vanno
prima ripristinate all'esatto hash precedente; l'installer rifiuta file estranei.
La copia/firma del bundle non aggiorna automaticamente una vecchia installazione
OpenGL già attiva dentro Windows.

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
- `probe-vulkan-buffer.c <DLL>`: trasferimento GPU/lettura4096byte tramite ICD esplicito e GPU hardware. Con `--multi` verifica quattrobuffer premappati (2095104/2095104/2095104/6144byte), marcatori/fill distinti, un submit e confronto completo dopo barrieraHOST/QueueWaitIdle. Con `--image` usa gli stessi buffer per quattrocopie di fasce da un’immagineottimale1536×1024/RGBA8 riempita dirosso, verificando tutti i pixel. Non qualifica WSI, OpenGL o fluidità.

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


## Misura presentazione WGL per il requisito Creality del3novembre

`windows-zink-present-timing.patch` è sola diagnostica opt-in sul fallback GDI,
non un miglioramento prestazionale o payload ordinario. Nessun ramo nominativo
Creality: misura qualunque presentazione WGL/Zink su questo percorso. Con
`PERP_WGL_PRESENT_TRACE` impostato a un file privato nel solo processo di prova,
registra al massimo600presentazioni: timestamp monotono, PID/TID, geometria,
numeroMap/esito, durata totale, sync threaded-context, Map, conversione, Unmap e
StretchDIBits. Include il tempo di attesa nel Map; non è tempo GPU puro. Le durate
non includono la scrittura della riga, ma gli intervalli tra righe sì: confronti
prestazionali finali richiedono anche prova senza tracing. Non sono FPS dello
schermo Mac o contatori dei frame persi. Idle e dimensioni diverse vanno separati.

Ricetta incrementale sulla cache locale qualificata M1x64/Mesa25.1.9:

```sh
python3 scripts/build-wgl-present-timing.py   --cache /private/path/perpendicular-opengl-cache   --output /private/path/new-diagnostic-output   --meson /private/path/tools/bin/meson --ninja /private/path/tools/bin/ninja
```

La ricetta richiede Meson1.12.1 come la cache, verifica SHA della funzione/base e
DLL0.2.31, prende un lock, conserva backup nel nuovo output e ripristina sorgente
ed esatto DLL qualificato anche se compilazione fallisce. Conservare la cache,
SDK e wrapper esistenti; dipendenze Python della cache ripristinate per questa
prova: Mako1.3.10/PyYAML6.0.3 e Ninja1.13.0. Il resto dei sorgenti/toolchain resta
la base descritta sopra. Non eseguire due build esterne sulla stessa cache.
Il binario diagnostico ha un hash distinto, non soddisfa il gate del payload
ordinario e non viene automaticamente distribuito/installato. Per il controllo
applicativo serve registrare esattamente DLL caricata, gesto reale e output;
compilazione riuscita da sola non qualifica la misura né il guadagno.


### Candidate readback del3novembre

La misura in Creality reale trova Map/attese dominanti (circa296ms su311ms,
quattro fasce, campione startup/resize). Non è ancora FPS di movimento né tempo
GPU puro. Il probe ora dispone di `--large-present`:1536×1024 DPIaware, shader,
profondità e pixel della finestra su più fasce. È un controllo circoscritto per
rifiutare errori di presentazione, non un benchmark dell'app.

`--batch-readback` riproduce una candidata **respinta**. Raccoglie le copie in
buffer≤2MiB e aspetta una volta. V1, variante ordinata e variante con pre-map
compilano ma sbagliano i pixel della finestra. Il controllo seriale equivalente
passa. La patch conservata è l'ultima variante respinta, non va installata o
promossa;43ms di un frame scorretto non sono un miglioramento. Nessuna di queste
DLL è entrata in Creality o nel payload ordinario. Per riprenderla servono nuova
evidenza di correttezza/causa, non un altro confronto FPS dello stesso codice.

`--reuse-readback` prepara invece una candidata circoscritta: un solo staging
colore/coerente≤2MiB percontext, riusato quando non ci sono altri transfer che lo
possiedono, con copia e fence per ogni fascia conservati. Mapping mantenuto e
rilasciato con la risorsa alla distruzione del context; percorsi diversi o
buffer occupato mantengono il comportamento precedente. Opt-in nel solo processo
con `PERP_ZINK_REUSE_READBACK=true`. Buildx64 e pixel del frame grande PASS;
log conferma riuso effettivo. Un frame nel probe77ms contro103ms seriale non
qualifica un guadagno applicativo: Map circa59/58ms, conversione/GDI differenti.
Prima prova Creality con modulo effettivo A725: mediana69ms contro311ms del riferimento precedente, ma geometria/startup differiscono. Confronto fresco stessoDLL A725/envfalse, stessa geometria1488×1107/cubo:316ms contro69ms con riuso. CostoWGL migliorato; fluidità continua senza trace e distribuzione principale ancora DA FARE. Il requisito è
fluidità utilizzabile con contenuti corretti, non la sola compatibilità.

La ricetta conserva hash dei sorgenti modificati, lock e backup/ripristino della
cache; limita il parallelismo per convivere con la VM M1. Le due opzioni sono
mutuamente esclusive e non cambiano i requisiti/payload della release. Solo una
correzione qualificata può aggiungere un nuovo profilo e requisito al gate della
build ordinaria. [Evidenze e fallimenti](../../docs/VERIFICATION.md#3-novembre--costo-readback-creality-e-prime-candidate-respinte).


## Confronto completo del batch respinto

Dopo il riscontro utente «scatta ancora molto» sulla produzione.33, il requisito
usabilità rimane NON SUPERATO. La diagnostica `--batch-readback --compare-readback`
aggiunge `windows-zink-readback-compare.patch`: con envprocess-local
`PERP_WGL_BATCH_READBACK=true` e `PERP_WGL_COMPARE_READBACK=true` confronta tutti i
byte dello stesso bitmap batch/seriale e presenta **sempre il seriale**. Il PASS
finestra di questa modalità non è un PASS del batch. Primo1536×1024:1618148byteRGB
diversi su1024righe prima diGDI. Ora osserva anche identità/mapping/contenuto delle
fasce, senza cambiare l'algoritmo V3. Nessuna promozione o nuovoFPS dimostrato;
artefatti/test privati e corrispondenti ricevute nel diario.


Il confronto diagnostico può inizializzare gli staging coerenti con marcatori
CPU distinti e controllare tutto il backing prima delle copie: il caso reale
non sovrappone i quattro buffer, ma la prima fascia resta non scritta. Queste
scritture diagnostiche alterano il contenuto iniziale e non sono un benchmark.
La variante `--batch-host-read` è riproducibile ma respinta: aggiungere la barriera
versoHOST non corregge i dati. `PERP_WGL_COMPARE_QUEUE_IDLE=true`, nel solo processo
con compare attivo, serve a distinguere completamento insufficiente da copie
errate; registra esito e stato della coda. Non è una modalità produzione o un
motivo per promuovere un batch dal PASS della sola finestra seriale.

La diagnostica confronto accetta anche `PERP_WGL_COMPARE_QUEUE_IDLE=true`: attende la coda completa dopo la fenceZink e registra l’esito. Sul M1 non corregge i byte errati, come la variante hostread; non è un’ottimizzazione da distribuire. Il probe Vulkan diretto `--multi` invece passa tutti i word: separa il semplice backing multi-buffer dal caso immagine/Zink ancora aperto.

Il confronto registra anche `WGL_COMPARE_COPY` nel punto effettivo `CmdCopyImageToBuffer`: immagine/buffer/comando/layout/offset/area per batch e seriale. La ricetta verifica e ripristina anche `zink_context.c`; le identità dei buffer da sole non dimostrano che i comandi li usino correttamente.

`windows-zink-batch-box.patch` / `--batch-box` corregge gli inizializzatori della variante batch usando `u_box_2d`: nella base Mesa25.1.9 `pipe_box` è ordinato x,width,y,height,z,depth. Le versioni precedenti copiavano aree sbagliate (anche larghezza0); barriere/attese non ne erano la soluzione. La patch resta separata per riprodurre gli esiti negativi. ConfrontoCPU integrale e finestra con batcheffettivo PASS sul M1; performance Creality ancora da qualificare, nessun default/release nuovo.

`windows-zink-batch-cache.patch` aggiunge il pool limitato alla variante corretta. Ricetta diagnostica `--batch-readback --batch-box --cached-batch` (include anche `windows-zink-readback-cache.patch` per mantenere il fallback .33). Massimo 16 risorse/32 MiB nel pool, ciascun mapping ≤2 MiB; solo buffer coerenti e senza altri proprietari, sostituzione del gruppo inattivo al resize/formato e rilascio dopo l'attesa già presente alla distruzione del contesto. Oltre il limite usa il seriale. `PERP_WGL_BATCH_READBACK=false` permette il controllo seriale .33 nello stesso DLL; `PERP_WGL_BATCH_CACHE=false` disattiva soltanto il pool. Con `--large-repeat` il probe presenta tre immagini diverse per controllare il riuso senza accettare contenuti vecchi. Build x64/pixel/riuso PASS sul M1, prestazioni Creality e distribuzione ordinaria ancora DA FARE. Nessuna nuova release o requisito minimo: le candidate non entrano nel packager.

`windows-zink-batch-control.patch` / `--batch-control` è solo diagnostica e richiede `--cached-batch`: il file indicato da `PERP_WGL_BATCH_CONTROL` contiene un byte ASCII `0` (seriale.33) o `1` (batch/cache). Il processo lo legge tra le presentazioni; file assente/illeggibile o altro valore conserva l'opzioneprocesso. Nessun comando viene eseguito. Consente un confronto nella stessa sessione senza cambiare DLL/viewport o riavviare Creality; trace`batch` identifica il percorso effettivo. Sul M1 entrambi i valori passano i tre frame diversi1536×1024 e il trace conferma0/1. Questo qualifica lo strumento, non FPS/Creality; non includere controllo/trace nella release ordinaria.

Perimetro dei tempi: `total_ns` copre il corpo della presentazione GDI in `wgl.c`, non tutto SwapBuffers. Flush del contesto, eventuale attesa swap-interval e altro lavoro a monte possono precederlo. Gli intervalli tra record non sono automaticamente FPS Mac o tempoCPU dell'applicazione; richiedono input continuo correlato e, per attribuire il residuo, misura del confine appropriato.
