# Prima implementazione

## Strumenti scelti

- Swift, AppKit e Metal sul Mac: finestre, input, presentazione delle immagini e processi della VM attraverso le API native, senza un motore intermedio separato.
- Rust ARM64 su Windows: un componente compilato per le API Win32, l'integrazione della sessione e la cattura delle finestre. Lo stesso linguaggio viene usato fin dal primo componente eseguibile.
- QEMU con Hypervisor.framework, inizialmente con display standard e senza accelerazione 3D del guest. Il runtime è una dipendenza esterna; non viene importata l'applicazione del progetto precedente.
- Una copia APFS indipendente della VM già installata evita di ripetere l'installazione dell'ISO. Le modifiche alle integrazioni vengono applicate alla copia.

## Metodo

Completare un percorso minimo con una finestra, input e riconnessione prima di aggiungere funzioni. Limitare le verifiche a compilazione, uso reale e casi di recupero pertinenti; ampliare i controlli soltanto quando emerge un problema concreto.

## Percorso scelto

La prima finestra funziona con Windows Graphics Capture, creata per un singolo HWND. Il dispositivo D3D11 usa esplicitamente WARP, quindi il percorso iniziale non richiede accelerazione 3D della VM. Si inviano i pixel della superficie della finestra e delle finestre secondarie riconosciute. Sul Mac AppKit gestisce le finestre native e Metal presenta i contenuti.

Questo è il percorso iniziale verificato su questa macchina; RemoteApp/RAIL/RDPEGFX rimangono alternative da provare su entrambe le estremità. Non è stata verificata una loro incompatibilità con Windows ARM. Fonti: [CreateForWindow](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow), [D3D11CreateDevice](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice).

Un servizio Rust avvia e sorveglia il worker nella sessione interattiva dell'utente. Il worker si connette al listener Mac su loopback attraverso il gateway NAT della VM. Il protocollo 1 usa JSON con lunghezza esplicita e payload BGRA separato; handshake con token locale, identità della sessione, heartbeat e riconnessione. Le richieste e le code sono limitate. Ogni finestra conserva solo il frame più recente in attesa, per evitare un accumulo di immagini obsolete.

I comandi di avvio non vengono ritentati automaticamente. La riconnessione ritrova le finestre per processo, tempo di creazione e sessione; non rilancia le app. L'input usa identità opache della finestra e una generazione della geometria; rilascia tasti e pulsanti alla disconnessione.

Per le app confezionate l'attivazione Shell può riusare una finestra senza restituire un processo o creare un nuovo HWND. Il catalogo conserva l'identità di attivazione e la confronta con l'[AppUserModelID del processo](https://learn.microsoft.com/en-us/windows/win32/api/appmodel/nf-appmodel-getapplicationusermodelid). Restano i controlli su utente e sessione; il titolo non è un'identità affidabile.

## Confini per gli aggiornamenti

| Componente attuale | Aggiornamento possibile | Contratto da conservare / nuova verifica |
| --- | --- | --- |
| `VirtualMachineController` e QMP | Altro motore, disco, firmware o driver | Avvio/stato/arresto/console; verificare boot, driver e dati della VM |
| Servizio e worker Rust | Trasporto vsock, autenticazione più forte, aggiornamento guest | Versione/capacità, sessione, richieste con esito, riconnessione senza duplicati |
| `capture.rs`, frame BGRA | Compressione, aggiornamenti parziali, codifica video | Finestra, dimensioni, generazione, sequenza e coda limitata; misurare qualità e latenza |
| Catalogo e osservazione Win32 | Migliore associazione delle app confezionate, icone, accessibilità | Identità app/finestra, avvio accettato distinto da contenuto pronto, dialoghi |
| `GuestBridge` e finestre AppKit | RemoteApp/RAIL/RDPEGFX | Adattare gli eventi del prodotto; verificare sessione, focus, ridimensionamento e finestre secondarie |
| RAMFB e WARP | Accelerazione 3D del guest | Sostituire driver/backend con rollback della VM; ripetere cattura e input |

La sostituzione di un codec o del trasporto non richiede di riscrivere il catalogo o le finestre Mac. Il cambio di modello di sessione, ad esempio con RemoteApp, può richiedere un adattatore e nuove prove: non è un cambio gratuito.

## Limiti della base

- Massimo quattro finestre principali/dialoghi e dodici superfici temporanee, 8.388.608 pixel per frame e frequenza limitata; pixel non compressi, nessuna prestazione generale dichiarata. Il limite è sufficiente per una superficie 3840×2160, ma non prova che il driver guest offra quella modalità.
- Catalogo AppsFolder senza icone specifiche e senza cache persistente. L'associazione iniziale delle app confezionate è semplice e può fallire esplicitamente.
- Tastiera normale e scorciatoie principali; IME, compatibilità con altri tipi di popup, accessibilità remota, audio, appunti e condivisione file richiedono lavoro dedicato. Le app elevate e il desktop protetto si gestiscono dalla console Windows.
- Il testo già composto sul Mac viene consegnato come messaggi UTF-16 al controllo Windows che possiede il focus, con un tempo massimo per la risposta. Mouse, tasti speciali e scorciatoie usano SendInput. Le prove con soli pacchetti Unicode e con traduzione attraverso il layout hanno riprodotto caratteri, maiuscole e lettere errati in Blocco note, anche introducendo una pausa; questo giustifica la separazione. I controlli che richiedono esclusivamente input hardware/Raw Input non sono coperti dalla prima verifica.
- Il collegamento è locale con token e non usa TLS. Non è progettato per esporre il listener su LAN/Internet o per isolare utenti ostili nella stessa VM.
- La configurazione della macchina e il bootstrap sono ancora strumenti di sviluppo; non esiste ancora una procedura guidata per distribuire il prodotto ad altri utenti.

## Build locale

`scripts/build-guest.sh` compila il binario Windows ARM64 con Rust e cargo-xwin (SDK Microsoft, CRT statico). `scripts/build-macos.sh` compila Swift 6 e include QEMU, swtpm e la chiusura delle relative librerie da Homebrew. Servono Xcode command line tools, Rust con target `aarch64-pc-windows-msvc`, cargo-xwin e le formule `qemu` e `swtpm`.

Il pacchetto di sviluppo è `.build/Perpendicular.app`, firmato ad hoc; contiene QEMU con entitlement Hypervisor, licenze e manifest dei binari. Può includere il solo runtime Native3D preparato e verificato come descritto sotto. Non include dischi, token o vecchi agenti. La macchina locale è in `~/Library/Application Support/Perpendicular Restart/`.

Per aggiornare il guest della macchina locale già avviata: compilare il guest, eseguire `python3 scripts/bootstrap-guest.py`, aprire la console Windows ed eseguire `D:\install.cmd`. Il CD con il token resta nella cartella privata della macchina. `SKIP_RUNTIME=1 scripts/build-macos.sh` consente di ricompilare il frontend senza sostituire il runtime già incluso; è il percorso da usare mentre la VM è in esecuzione.

Il firmware e lo stato TPM della copia vengono mantenuti compatibili con l'installazione Windows esistente. Questo riusa un sistema installato, non equivale a un'installazione nuova dall'ISO. Il bootstrap rimuove le integrazioni riconosciute e ripristina le cartelle reindirizzate; il rapporto dopo il riavvio viene salvato fuori Git come `guest-diagnostics.json`.

La diagnostica di pulizia è una funzione di sviluppo opzionale (`PERPENDICULAR_AUDIT=1` all'avvio del frontend). Non viene eseguita nel normale collegamento. Il worker la esegue separatamente dai comandi delle finestre, con un limite di tempo e una sola richiesta attiva: un controllo amministrativo lento non deve bloccare l'input. Il rapporto include il momento di boot; controllarne sempre data e freschezza. Un errore viene scritto in `guest-diagnostics-error.txt`.

## Finestre principali, dialoghi e superfici temporanee

Il guest descrive ruolo (`main`, `dialog`, `popup`, `tooltip`), proprietario associato, rettangolo in coordinate Windows, ordine, visibilità e riduzione. Classe, stili e relazione con il proprietario distinguono i popup senza cornice dai dialoghi; `WS_POPUP` da solo non è sufficiente. I popup Chromium senza proprietario esplicito vengono associati alla finestra attiva dello stesso processo oppure alla più vicina. È una classificazione pratica, verificata con Blocco note e Edge, non una garanzia per qualsiasi toolkit.

Le finestre principali usano una finestra AppKit senza barra e la cattura completa del bordo Windows. I dialoghi conservano il bordo Mac e ricevono solo il contenuto client Windows. I popup usano pannelli figli non attivanti, senza barra e senza voce nel menu Window: vengono posizionati relativamente all'immagine del proprietario e ordinati come nel guest. Le superfici vengono catturate separatamente con WGC; `IncludeSecondaryWindows` resta disattivato per evitare la duplicazione dei dialoghi e il taglio dei popup ai bordi della finestra principale.

Il mouse usa l'origine della superficie catturata, compresa la parte non client. Il passaggio del cursore non forza l'attivazione di una finestra Windows; click e tastiera mantengono il focus nella famiglia associata, consentendo ai popup di ricevere input attraverso la finestra Mac principale. Le superfici temporanee nascoste vengono ritirate e non vengono salvate fra le finestre da ripristinare. L'osservazione è attualmente a intervalli di 75 ms. La riduzione nel guest aggiorna la rappresentazione Mac, mentre la posizione principale resta locale; il menu Window mantiene esplicitamente le finestre principali senza barra.

## Drag locale e resize controllato

La posizione Mac è indipendente dalla posizione della finestra Windows. Il guest risponde a una richiesta breve WM_NCHITTEST per distinguere barra, schede, controlli e bordi; il frontend esegue localmente il movimento della finestra Mac. Durante l'attesa conserva l'ultimo movimento e il rilascio, così anche un click rapido non lascia il gesto sospeso. I pulsanti e il contenuto dell'app continuano a ricevere input Windows.

Per le finestre principali senza barra, il resize viene gestito dai bordi espliciti del frontend; il tracking implicito delle finestre borderless AppKit è disattivato per evitare due gestori concorrenti. I veri dialoghi conservano il normale bordo ridimensionabile AppKit.

Il resize aggiorna subito il contenitore Mac e invia dimensioni intermedie durante il gesto, con una sola richiesta in corso e l'ultima misura ancora da inviare. Un intervallo minimo evita di accodare ogni evento del mouse. Al rilascio viene inviata la misura finale e atteso il frame corrispondente; le risposte del gesto precedente sono ignorate. Se un aggiornamento intermedio fallisce, si passa alla riconciliazione finale senza riempire la coda di nuovi tentativi. Il guest limita la dimensione all'area di lavoro attuale e mantiene la superficie raggiungibile dal mouse. Il frontend consulta la geometria effettiva se l'app impone minimi propri; un timeout sblocca comunque l'interazione. Il massimo e il doppio click sulla barra usano lo stesso percorso.

I rilasci di mouse e tastiera vengono processati prima di verificare identità della finestra e generazione dell'immagine, senza spostare il puntatore su coordinate obsolete. L'annullamento di un'interazione rilascia l'input e invia WM_CANCELMODE alla finestra interessata. Le superfici temporanee restano ancorate relativamente al contenuto; il loro proprietario non segue più i movimenti del guest sul desktop Mac.

Tre controlli mirati della geometria sono in tests/WindowGeometryChecks.swift e si compilano insieme a macos/WindowGeometry.swift con swiftc. Le prove interattive e i limiti osservati restano in VERIFICATION.md.

## Presentazione Metal e rilevamento dei monitor

`WindowRenderer.swift` presenta ogni superficie tramite CAMetalLayer. La texture BGRA viene riutilizzata soltanto dopo il completamento del lettore GPU; durante l'attesa rimane unicamente il frame CPU più recente. Ridimensionamento e cambi di scala aggiornano il drawable usando i pixel di backing del monitor Mac. La creazione di CGImage avviene soltanto per diagnostica o recupero in caso di indisponibilità di Metal, non per ogni frame del percorso ordinario. Un errore Metal viene riportato al frontend.

Il trasporto resta CPU BGRA: staging/readback Windows, invio TCP e caricamento nella texture Mac. Non è zero-copy e la cattura guest resta WARP. Il ricevitore accumula i blocchi nel medesimo buffer, evitando di ricopiare i blocchi precedenti a ogni lettura. Non sono ancora misurati guadagni di latenza o throughput.

`display_info` legge in Rust monitor attivi, modalità esposte, coordinate e DPI. La creazione del dispositivo Direct3D è separata in `graphics_info`, una prova esplicita fuori dal ciclo dei comandi: un driver lento non deve bloccare catalogo e input, né essere inizializzato a ogni normale collegamento. `HostDisplay` conserva separatamente punti e pixel dei monitor Mac; con `PERPENDICULAR_STATE_TRACE=1` il confronto host/guest, la prova grafica opzionale e il primo completamento GPU Metal vengono scritti nella diagnostica privata. La lettura non cambia risoluzione, scala o driver. Microsoft Basic Render Driver viene riconosciuto anche tramite gli ID `1414:008C`: può riuscire una richiesta D3D HARDWARE senza che il flag SOFTWARE sia impostato. [Descrizione Microsoft](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/d3d10-graphics-programming-guide-dxgi).

## Preparazione del runtime grafico di riferimento

`scripts/prepare-native-graphics.py SOURCE OUTPUT [--qemu ORIGINAL_QEMU]` prepara solo gli artefatti Native3D in una nuova cartella privata. Verifica versioni del protocollo e hash di tutti i file prima della copia e conserva licenze, patch e metadati da `ThirdPartyNotices/Native3D`. L'eventuale QEMU alternativo deve coincidere esattamente con l'hash del manifest: non permette di mescolare build arbitrarie. Non importa la vecchia app, agenti, sharing o configurazioni della VM.

Il runtime preparato viene incluso da `build-macos.sh` quando presente in `.build/Native3D`; è selezionabile nella configurazione privata della macchina con `graphics: "native3D"`. Il profilo standard rimane il percorso di recupero. Il profilo Native3D usa QEMU 10.0.12 con il backend senza finestre, il broker di scanout e il dispositivo ibrido RAMFB/VirtIO GPU. La prima configurazione da qualificare ha una sola uscita; il supporto a più monitor richiede ancora integrazione e verifica. Entrambi i profili ricevono le risorse QEMU attraverso `-L`, comprese le mappe tastiera necessarie a VNC. La verifica dei file e la selezione del profilo non dimostrano accelerazione Windows o cattura accelerata per finestra.

Nel profilo Native3D il boot usa una sola uscita a `1280×800`; dopo la connessione interattiva il frontend annuncia via RFB la dimensione del monitor Mac primario. `display_configure` applica esplicitamente la modalità Windows con [ChangeDisplaySettingsExW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexw), dopo averne controllato l'accettazione con CDS_TEST. Il cambio di monitor è distinto dal resize di una singola app. Le code delle operazioni sui monitor e della prova Direct3D sono separate: un probe hardware in corso non impedisce la lettura o la configurazione del display. La richiesta non imposta ancora la scala DPI e non configura più uscite.

Il collegamento interattivo può precedere la disponibilità del driver a cambiare modalità. Il frontend effettua al massimo tre tentativi distanziati, annullati alla disconnessione o al cambio di epoch; non avvia un ciclo infinito di riconfigurazione. La riconciliazione di una finestra che cambia misura nel guest la mantiene raggiungibile sul monitor Mac quando vi può rientrare.

### Desktop integrato e runtime persistenti

`Show Windows` apre una finestra della stessa app, con presentazione Metal e input sul socket RFB privato. Nel profilo standard QEMU gira con `-display none`; il desktop completo resta disponibile senza una seconda app Cocoa. Il socket risiede in una directory privata creata per l'avvio e il relativo stato identifica macchina e processo. La console tenta di riconnettersi mentre è visibile e rilascia l'input quando perde il focus o viene chiusa. Il protocollo implementato è il sottoinsieme necessario di [RFB 3.8](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst), con pixel grezzi e notifiche di dimensione.

Quando il backend Native3D produce una superficie valida, `NativeDisplayReader` importa la memoria condivisa nella texture Metal e sospende le richieste di pixel RFB. L'input della console conserva il proprio collegamento. Il trasporto C MIT proviene dal componente selezionato del vecchio progetto: verifica identità, sessione, dimensioni e completamento del produttore. Il frame rimane vivo fino all'ultimo comando GPU che lo legge; solo allora può essere confermato al produttore. Una disconnessione non autorizza a riutilizzare la memoria ancora letta dalla GPU. Questo percorso riguarda il desktop; le singole finestre continuano a usare il trasporto BGRA esistente finché non viene integrato un percorso dedicato.

Il presenter conserva ora una texture Metal propria per l'ultima immagine nativa. Esegue una copia GPU dalla superficie condivisa e la conferma dopo il completamento del comando, senza attendere un'immagine successiva. Questo elimina l'attesa circolare fra una vecchia immagine ancora visualizzata e il budget necessario al nuovo produttore. Ridisegno e resize del contenitore riusano la texture locale; questo percorso comprende una copia GPU e non va descritto come zero-copy.

La [patch del ciclo dei contesti](../graphics/renderer/README.md) modifica soltanto il renderer e il relativo server: la terminazione normale è confermata dopo la raccolta effettiva del processo figlio, prima di liberare il budget del broker. Le vecchie immagini prestate conservano la propria durata e i propri identificatori completi. Un esito non confermato mantiene chiusa la cattura. `rebuild-native-renderer.py` prepara una coppia corrispondente da input grafici vincolati agli hash, in una nuova directory privata, senza modificare il progetto di riferimento. Il manifest distingue il protocollo di controllo host versione 2; il protocollo guest e il formato delle immagini restano invariati. Esaurimento delle risorse e catture visivamente incomplete restano limiti separati.

`RuntimeStore` copia QEMU, librerie, risorse ed eventuale Native3D in `Runtimes/<hash>/` nella cartella privata della macchina, conservando i percorsi relativi. L'identità comprende contenuti, percorsi e collegamenti interni; la copia viene verificata prima della pubblicazione. Le versioni precedenti non vengono sovrascritte né rimosse mentre una VM può usarle. Una pulizia di `.build` o una nuova compilazione non devono eliminare gli eseguibili e le librerie dei processi già avviati.

Il menu `Perpendicular → Recovery Display` commuta il display di recupero. Chiede l'arresto regolare di Windows e cambia configurazione soltanto quando la VM è spenta; un timeout lascia invariata la scelta. Il flag privato `recoveryDisplay` conserva il profilo grafico preferito e permette di tornarvi togliendo la spunta. Non forza spegnimenti e non cambia driver o protezioni Windows. Il backend Native3D resta sperimentale: i limiti osservati di UAC, immagini e durata del broker sono riportati in VERIFICATION.md.

### Preparazione del guest e ritorno al percorso standard

`scripts/checkpoint-machine.py [--shutdown]` prepara un checkpoint offline APFS di configurazione, disco, EFI e TPM. Richiede che la copia sia spenta regolarmente e verifica l'identità del processo prima di chiederne l'arresto. Non forza spegnimenti, non ripristina automaticamente il disco e non modifica la VM originale.

Il driver ARM64 è fissato in `guest/graphics-driver.json`, dalla [release v0.3](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.3). `bootstrap-guest.py --graphics-driver-dir PATH` aggiunge al CD solo gli undici file corrispondenti agli hash previsti. `install-graphics.cmd` richiede l'elevazione normale; lo script verifica nuovamente i file e la firma attendibile del catalogo, poi usa pnputil. Non disattiva protezioni Windows e non forza riavvii. Conservare il checkpoint prima del cambio di driver e selezionare il profilo solo a VM spenta.

### Esperimenti di display e direzione corrente

Il vecchio 2D non è una base approvata. I preparatori del runtime QEMU 11 e del driver DOD sono isolati in [experimental/display-reference](../experimental/display-reference/README.md), esclusi da app, guest e CD ordinari. Il comando locale di installazione DOD è stato rimosso dal guest. La build elimina l'eventuale vecchia risorsa `Display2D`; una configurazione storica `virtio2D` può soltanto usare Recovery, senza avviare quell'esperimento.

Il menu Display offre Standard e 3D sperimentale. Cambia profilo dopo l'arresto regolare della VM; durante il riavvio le scelte sono disabilitate. Standard/Recovery usano RAMFB e conservano il limite attuale di 800×600. Il selettore host non installa driver: dopo la preparazione DOD della copia di sviluppo, il pacchetto 3D firmato va eventualmente reinstallato prima di riprovare Native3D.

L'analisi statica di Parallels 26.3.0 ha individuato controller distinti per configurazione display, input, attivazione, ordine e finestre, oltre a controlli di disponibilità della risoluzione dinamica e code con identificatori di risposta. Ne ricaviamo vincoli progettuali: stato reale dei monitor prima delle coordinate condivise; comandi identificati e riconciliati; immagini separabili dal controllo. Non dimostra il percorso interno completo di Coherence, una corrispondenza con i nostri protocolli o assenza di copie.

Per il prossimo esperimento si valuta RDP con [MS-RDPEDISP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/bdc90b21-4b14-43bc-9c03-b7fecbfc6a1f): risoluzione, disposizione e scala appartengono al display della sessione remota, senza richiedere il nostro driver 3D. Non aggiunge semplicemente un monitor alla console: worker, cattura e input devono vivere nella sessione RDP autenticata. La copia Windows è Professional; connessione, cattura WGC e riconnessione in quella sessione restano da provare. La prima prova deve mantenere l'output server attivo; disabilitare la decodifica locale non equivale a inviare Suppress Output. FreeRDP viene valutato tramite API C, senza sostituire Swift/AppKit/Metal o il worker Rust.

L'alternativa IddCx è un driver C++ UMDF per monitor virtuali indipendente dal 3D, ma richiede toolchain WDK e un pacchetto ARM64 dalla firma effettivamente accettata. Le API IddCx di aggiornamento DPI dei remote IDD non sono disponibili liberamente a un driver della console. Non sono autorizzati per questa strada test signing o disattivazione di Secure Boot. [Modello Microsoft](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview), [limiti remote IDD](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx1.4-updates-for-remote-idds).

### Stato effettivo del display

`display_info` riporta anche l'area di lavoro del monitor in pixel Windows. Il frontend legge lo stato dopo il collegamento, all'aggiornamento manuale e al cambiamento degli schermi Mac o Windows. Le risposte appartenenti a un'altra connessione o a una richiesta superata non pubblicano il vecchio stato. La UI mostra risoluzione e scala realmente lette, indipendentemente dalla diagnostica.

`SharedDisplay` ammette la corrispondenza del solo monitor primario quando risoluzione e DPI effettivi coincidono esattamente con backing e scala Mac. Converte rettangoli nei due versi, con origini esplicite e inversione Y. È un contratto verificato matematicamente, non una prova di monitor dinamici: non abilita ancora la sincronizzazione delle posizioni. Il display RAMFB a 800×600/96 DPI non soddisfa il contratto del Mac attuale. Il supporto completo a più monitor rimane da implementare e verificare.

Su richiesta esplicita dell'utente, la sola copia Windows di sviluppo è stata impostata manualmente su UAC «Non notificare mai». È una preferenza una tantum della VM, non un comportamento dell'installer o del guest tool. Non viene impostato `EnableLUA=0`: [Microsoft distingue](https://learn.microsoft.com/en-us/windows/win32/secauthz/user-account-control) l'eliminazione delle notifiche dalla disattivazione completa di UAC. Gli installer continuano a chiedere a Windows l'elevazione con `RunAs`; con questa preferenza l'amministratore non riceve il popup.

La chiave privata `keyboardLayout` sceglie la mappa della tastiera RFB fra quelle incluse nel pacchetto; il valore iniziale implicito resta `en-us`. Serve a far corrispondere i simboli della console al layout Windows effettivo. È separata dall'input Unicode delle singole app e non cambia le preferenze della tastiera Mac o Windows.

`driver_info` legge pacchetto, servizio, presenza e codice di problema dei dispositivi display tramite SetupAPI in Rust, senza caricare il provider PnpDevice di PowerShell. È separato dalla query rapida dei monitor e dalla configurazione del display, così una lettura lenta non occupa il loro stato. Il rapporto completo delle integrazioni precedenti rimane una diagnostica esplicita: lo script è passato a PowerShell come comando unico e il worker drena contemporaneamente output ed errori con limiti di dimensione e tempo. Un timeout di quella raccolta non impedisce catalogo, input o lettura nativa dei driver.
