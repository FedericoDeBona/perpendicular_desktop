# Prima implementazione

## Strumenti scelti

- Swift e AppKit sul Mac: finestre, input e processi della VM attraverso le API native, senza un motore intermedio separato.
- Rust ARM64 su Windows: un componente compilato per le API Win32, l'integrazione della sessione e la cattura delle finestre. Lo stesso linguaggio viene usato fin dal primo componente eseguibile.
- QEMU con Hypervisor.framework, inizialmente con display standard e senza accelerazione 3D del guest. Il runtime è una dipendenza esterna; non viene importata l'applicazione del progetto precedente.
- Una copia APFS indipendente della VM già installata evita di ripetere l'installazione dell'ISO. Le modifiche alle integrazioni vengono applicate alla copia.

## Metodo

Completare un percorso minimo con una finestra, input e riconnessione prima di aggiungere funzioni. Limitare le verifiche a compilazione, uso reale e casi di recupero pertinenti; ampliare i controlli soltanto quando emerge un problema concreto.

## Percorso scelto

La prima finestra funziona con Windows Graphics Capture, creata per un singolo HWND. Il dispositivo D3D11 usa esplicitamente WARP, quindi il percorso iniziale non richiede accelerazione 3D della VM. Si inviano soltanto i pixel dell'area client e le finestre secondarie riconosciute. Sul Mac AppKit presenta i contenuti e gestisce le finestre native.

Questo è il percorso iniziale verificato su questa macchina; RemoteApp/RAIL/RDPEGFX rimangono alternative da provare su entrambe le estremità. Non è stata verificata una loro incompatibilità con Windows ARM. Fonti: [CreateForWindow](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow), [D3D11CreateDevice](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice).

Un servizio Rust avvia e sorveglia il worker nella sessione interattiva dell'utente. Il worker si connette al listener Mac su loopback attraverso il gateway NAT della VM. Il protocollo 1 usa JSON con lunghezza esplicita e payload BGRA separato; handshake con token locale, identità della sessione, heartbeat e riconnessione. Le richieste e le code sono limitate. Ogni finestra conserva solo il frame più recente in attesa, per evitare un accumulo di immagini obsolete.

I comandi di avvio non vengono ritentati automaticamente. La riconnessione ritrova le finestre per processo, tempo di creazione e sessione; non rilancia le app. L'input usa identità opache della finestra e una generazione della geometria; rilascia tasti e pulsanti alla disconnessione.

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

- Massimo quattro finestre principali/dialoghi e dodici superfici temporanee, circa quattro milioni di pixel per frame e frequenza limitata; pixel non compressi, nessuna prestazione generale dichiarata.
- Catalogo AppsFolder senza icone specifiche e senza cache persistente. L'associazione iniziale delle app confezionate è semplice e può fallire esplicitamente.
- Tastiera normale e scorciatoie principali; IME, compatibilità con altri tipi di popup, accessibilità remota, audio, appunti e condivisione file richiedono lavoro dedicato. Le app elevate e il desktop protetto si gestiscono dalla console Windows.
- Il testo già composto sul Mac viene consegnato come messaggi UTF-16 al controllo Windows che possiede il focus, con un tempo massimo per la risposta. Mouse, tasti speciali e scorciatoie usano SendInput. Le prove con soli pacchetti Unicode e con traduzione attraverso il layout hanno riprodotto caratteri, maiuscole e lettere errati in Blocco note, anche introducendo una pausa; questo giustifica la separazione. I controlli che richiedono esclusivamente input hardware/Raw Input non sono coperti dalla prima verifica.
- Il collegamento è locale con token e non usa TLS. Non è progettato per esporre il listener su LAN/Internet o per isolare utenti ostili nella stessa VM.
- La configurazione della macchina e il bootstrap sono ancora strumenti di sviluppo; non esiste ancora una procedura guidata per distribuire il prodotto ad altri utenti.

## Build locale

`scripts/build-guest.sh` compila il binario Windows ARM64 con Rust e cargo-xwin (SDK Microsoft, CRT statico). `scripts/build-macos.sh` compila Swift 6 e include QEMU, swtpm e la chiusura delle relative librerie da Homebrew. Servono Xcode command line tools, Rust con target `aarch64-pc-windows-msvc`, cargo-xwin e le formule `qemu` e `swtpm`.

Il pacchetto di sviluppo è `.build/Perpendicular.app`, firmato ad hoc; contiene una console QEMU nativa con entitlement Hypervisor, licenze e manifest dei binari. Non include dischi, token, vecchio motore grafico o vecchi agenti. La macchina locale è in `~/Library/Application Support/Perpendicular Restart/`.

Per aggiornare il guest della macchina locale già avviata: compilare il guest, eseguire `python3 scripts/bootstrap-guest.py`, aprire la console Windows ed eseguire `D:\install.cmd`. Il CD con il token resta nella cartella privata della macchina. `SKIP_RUNTIME=1 scripts/build-macos.sh` consente di ricompilare il frontend senza sostituire il runtime già incluso; è il percorso da usare mentre la VM è in esecuzione.

Il firmware e lo stato TPM della copia vengono mantenuti compatibili con l'installazione Windows esistente. Questo riusa un sistema installato, non equivale a un'installazione nuova dall'ISO. Il bootstrap rimuove le integrazioni riconosciute e ripristina le cartelle reindirizzate; il rapporto dopo il riavvio viene salvato fuori Git come `guest-diagnostics.json`.

La diagnostica di pulizia è una funzione di sviluppo opzionale (`PERPENDICULAR_AUDIT=1` all'avvio del frontend). Non viene eseguita nel normale collegamento. Il worker la esegue separatamente dai comandi delle finestre, con un limite di tempo e una sola richiesta attiva: un controllo amministrativo lento non deve bloccare l'input. Il rapporto include il momento di boot; controllarne sempre data e freschezza. Un errore viene scritto in `guest-diagnostics-error.txt`.

## Finestre principali, dialoghi e superfici temporanee

Il guest descrive ruolo (`main`, `dialog`, `popup`, `tooltip`), proprietario associato, rettangolo in coordinate Windows, ordine, visibilità e riduzione. Classe, stili e relazione con il proprietario distinguono i popup senza cornice dai dialoghi; `WS_POPUP` da solo non è sufficiente. I popup Chromium senza proprietario esplicito vengono associati alla finestra attiva dello stesso processo oppure alla più vicina. È una classificazione pratica, verificata con Blocco note e Edge, non una garanzia per qualsiasi toolkit.

Le finestre principali usano una finestra AppKit senza barra e la cattura completa del bordo Windows. I dialoghi conservano il bordo Mac e ricevono solo il contenuto client Windows. I popup usano pannelli figli non attivanti, senza barra e senza voce nel menu Window: vengono posizionati relativamente all'immagine del proprietario e ordinati come nel guest. Le superfici vengono catturate separatamente con WGC; `IncludeSecondaryWindows` resta disattivato per evitare la duplicazione dei dialoghi e il taglio dei popup ai bordi della finestra principale.

Il mouse usa l'origine della superficie catturata, compresa la parte non client. Il passaggio del cursore non forza l'attivazione di una finestra Windows; click e tastiera mantengono il focus nella famiglia associata, consentendo ai popup di ricevere input attraverso la finestra Mac principale. Le superfici temporanee nascoste vengono ritirate e non vengono salvate fra le finestre da ripristinare. L'osservazione è attualmente a intervalli di 75 ms. La riduzione nel guest aggiorna la rappresentazione Mac, mentre la posizione principale resta locale; il menu Window mantiene esplicitamente le finestre principali senza barra.

## Drag locale e resize controllato

La posizione Mac è indipendente dalla posizione della finestra Windows. Il guest risponde a una richiesta breve WM_NCHITTEST per distinguere barra, schede, controlli e bordi; il frontend esegue localmente il movimento della finestra Mac. Durante l'attesa conserva l'ultimo movimento e il rilascio, così anche un click rapido non lascia il gesto sospeso. I pulsanti e il contenuto dell'app continuano a ricevere input Windows.

Il resize mostra un'anteprima locale e invia una richiesta esplicita soltanto al rilascio. Il guest limita la dimensione all'area di lavoro attuale e mantiene la superficie raggiungibile dal mouse, senza modificare risoluzione, driver o dispositivo grafico. Il frontend attende i frame della nuova dimensione e consulta la geometria effettiva se l'app impone minimi propri; un timeout sblocca comunque l'interazione. Il massimo e il doppio click sulla barra usano lo stesso percorso.

I rilasci di mouse e tastiera vengono processati prima di verificare identità della finestra e generazione dell'immagine, senza spostare il puntatore su coordinate obsolete. L'annullamento di un'interazione rilascia l'input e invia WM_CANCELMODE alla finestra interessata. Le superfici temporanee restano ancorate relativamente al contenuto; il loro proprietario non segue più i movimenti del guest sul desktop Mac.

Tre controlli mirati della geometria sono in tests/WindowGeometryChecks.swift e si compilano insieme a macos/WindowGeometry.swift con swiftc. Le prove interattive e i limiti osservati restano in VERIFICATION.md.
