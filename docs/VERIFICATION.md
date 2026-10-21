# Prima verifica locale — 21 ottobre 2026

Queste sono prove su questa macchina e su una normale app Windows. Non dimostrano affidabilità generale o compatibilità con ogni applicazione.

## Risultati osservati

- La VM clonata avvia Windows con QEMU/HVF e RAMFB, senza un dispositivo grafico 3D. Il disco originale non è stato usato in scrittura.
- Il servizio Rust avvia il worker nella sessione interattiva; il frontend Swift riceve il catalogo di 68 applicazioni e apre Blocco note in una finestra Mac.
- Il testo finale `Perpendicular: nuova finestra Windows sul Mac. 0123456789` appare correttamente nell'editor, comprese maiuscole, punteggiatura e numeri.
- Il dialogo “Salva con nome” appare come finestra Mac separata. L'immagine grezza ricevuta, 609×441, contiene esclusivamente il dialogo. Il nome `Perpendicular-base.txt` viene inserito e il pulsante Salva azionato con il mouse; Blocco note mostra il nome del file salvato.
- Riavviando il frontend vengono ritrovate le app aperte e il testo. Anche gli aggiornamenti del servizio, che riavviano il worker e cambiano l'epoch della connessione, recuperano le due finestre esistenti senza comandi di rilancio.
- Dopo l'arresto regolare completo, l'app finale aperta dal suo pacchetto avvia nuovamente la VM e riceve il catalogo automaticamente. Il desktop Windows usa le cartelle locali, mostra le icone installate e non ripresenta l'errore su `M:\Desktop`. Blocco note viene riaperto dal catalogo e mostra `Perpendicular-base.txt` con il testo corretto salvato prima del riavvio.
- Il pacchetto contiene QEMU 11.1.2, swtpm 0.10.2 e 34 file nativi nella chiusura delle dipendenze. Controllo dei collegamenti dinamici e verifica delle firme ad hoc completati senza dipendenze esterne irrisolte. Il guest incluso coincide con il binario Rust compilato.

## Pulizia della copia

Il primo controllo dopo un boot ha trovato un residuo: il Desktop Windows puntava ancora a `M:\Desktop`. Sono state ripristinate le cartelle locali Desktop, Documents, Pictures, Music, Videos e Downloads nelle due chiavi Explorer interessate. I vecchi agenti riconosciuti sono stati rimossi dall'avvio e il relativo percorso messo da parte nella sola copia.

La verifica successiva nella console Windows ha riportato zero processi, servizi, attività pianificate, condivisioni, avvii e cartelle riferiti alle integrazioni precedenti; la vecchia directory Guest Agent non esiste più nella posizione di avvio. Il driver di visualizzazione `VioGpuDod` risulta installato, fermo e ad avvio manuale; non viene usato dal percorso RAMFB/WARP. Il sistema operativo conserva applicazioni e driver dell'installazione clonata.

I rapporti hanno data e momento di boot: non considerare un file precedente come un nuovo controllo. La diagnostica completa tramite PowerShell può superare il limite di sei secondi e restituire timeout. È opzionale, eseguita su un thread separato e disattivata nel normale avvio.

## Errori e limiti emersi

- Il primo runtime di sviluppo non aveva il backend Cocoa; quello finale proviene da Homebrew e include una console Mac separata. Durante il confezionamento sono stati corretti un ROM di rete cercato inutilmente e l'entitlement Hypervisor della console.
- I primi percorsi di invio del testo hanno prodotto caratteri ripetuti, maiuscole errate e lettere mancanti. L'introduzione di pause non è bastata. Il percorso finale consegna il testo composto al controllo con focus; le scorciatoie rimangono eventi di tastiera.
- La relazione tra finestra e dialogo viene applicata dopo aver creato tutte le finestre, per non dipendere dall'ordine degli eventi.
- Nella prima versione il ridimensionamento tramite trascinamento non era stato confermato dall'automazione Mac. La verifica del percorso aggiornato è riportata sotto; il limite del desktop guest RAMFB rimane 800×600.
- IME, app che richiedono Raw Input, finestre elevate, compatibilità generale con altri popup, icone specifiche, appunti e file condivisi non rientrano nella prima compatibilità verificata.

Le immagini grezze usate per controllare l'isolamento delle finestre restano nella cartella privata della macchina, in `QA/`, e non vengono generate nell'avvio normale.

## Aggiornamento: popup e bordo delle finestre

Verificati nella VM locale, senza accelerazione 3D guest:

- Edge: menu principale e popup Traduci sovrapposti al browser; Esc chiude Traduci. L'anteprima della scheda inattiva appare senza attivare una nuova finestra Mac e scompare spostando il cursore sul documento. La traccia identifica questi elementi come popup Chromium, con proprietario, rettangolo e ciclo di visibilità separati.
- Blocco note: File, Modifica, Visualizza e il sottomenu Zoom; selezionando Apri dal menu si apre un vero dialogo con i controlli Mac. Il pulsante Mac di chiusura chiude il dialogo Windows. Il documento esistente rimane invariato.
- Le finestre principali mostrano i controlli Windows e nessuna barra Mac. Il pulsante Windows di riduzione riduce anche la finestra Mac; dopo la riapertura del frontend, il menu Window ripristina Blocco note e la cattura del documento. La chiusura dal pulsante Windows è verificata su una nuova finestra vuota, preservando il documento originale.

Durante la verifica sono emersi e corretti l'assenza delle finestre senza barra dal menu Window e il rischio di catturare i dialoghi anche dentro l'immagine del proprietario usando IncludeSecondaryWindows. Quest'ultima opzione è stata disattivata: popup e dialoghi vengono presentati come superfici indipendenti. Il ripristino di una finestra ridotta dopo la riconnessione ha inoltre prodotto Invalid capture stride: la cattura ora aspetta il ripristino prima di creare il pool iniziale e scarta le texture transitorie più piccole del contenuto dichiarato. Con le superfici indipendenti, il confronto con la console ha rivelato che la politica AppKit hidesOnDeactivate poteva nascondere il pannello Edge pur lasciando aperto il popup nel guest: è stata disattivata e la visibilità segue ora il proprietario e gli eventi Windows. La prima compilazione Rust ha richiesto la correzione dell'import di IsWindowEnabled.

Il desktop guest resta 800×600: Windows può spostare i menu lunghi verso l'alto per farli rientrare nell'area disponibile. Questo aggiornamento non modifica la risoluzione né dichiara verificati tutti i toolkit, tutti i warning o il ridimensionamento/spostamento in ogni configurazione.

Build guest finale di questo aggiornamento: SHA-256 `d53c4c8932963b0ee85ae17d2abfd98ec5f809928b2d781e724d57637ee9c870`, coincidente con il binario nel pacchetto Mac. Firma del pacchetto verificata.

Nel pacchetto finale, aperto normalmente senza diagnostica, sono stati nuovamente osservati menu Edge, popup Traduci e anteprima della scheda come pannelli separati senza barra Mac; spostando il cursore sul documento l'anteprima scompare. IncludeSecondaryWindows è disattivato. Il documento Blocco note è tornato visibile dopo il ripristino dal menu Window.

Resta da affinare il passaggio del focus fra applicazioni: durante la verifica un'attivazione immediata è stata rifiutata da Windows e alcuni primi click hanno soltanto attivato la finestra; la prova dei popup è stata completata con l'app interessata attiva. Questo aggiornamento non certifica l'affidabilità generale di quel passaggio.

## Aggiornamento: drag locale, resize e rilascio dell'input

Verifica nella stessa VM, su Foto nella pagina Impostazioni, senza modificare immagini o preferenze:

- Il drag della parte libera della barra Windows sposta il contenitore Mac da `(160,111)` a `(260,51)`, esattamente di `(+100,-60)` punti. Il rettangolo Windows resta `(149,36,532,509)`: il movimento locale non trascina più la finestra sorgente nel desktop guest.
- Due resize dal bordo hanno prodotto nuove immagini e geometrie coerenti. Una richiesta `532×476` è stata corretta da Foto a `532×509`, rispettando il minimo dell'app. Il resize successivo a `582×520` è stato accettato; Windows ha portato la sorgente a `y=32` per mantenerla nell'area disponibile.
- Dopo ciascun resize, il click apre il selettore del tema e Esc lo richiude. Il tema rimane invariato. Non è stato necessario riavviare o riconnettere per recuperare l'input.
- Il pulsante Windows di ingrandimento applica `800×552`, quindi ripristina `582×520`. Entrambe le operazioni terminano con un'immagine della misura confermata. Il desktop resta `800×600`, con 48 pixel occupati dalla barra delle applicazioni.
- L'aggiornamento del servizio cambia l'epoch e recupera Foto già aperta. Il frontend ricompilato la ritrova anche dopo il proprio riavvio.
- Il pacchetto finale è stato riaperto normalmente, senza variabili diagnostiche, e mostra Foto con la dimensione ripristinata.
- Tre controlli della geometria Swift verificano limiti minimo/massimo e conservazione dell'angolo opposto. Build Rust e Swift e verifica della firma del pacchetto completate; guest incluso SHA-256 `c9bfb56c588bb94719a3863aeb4a3207602a70f7c052f0327fbaabafbbbecd3a`.

Errori emersi nelle iterazioni di questa modifica: un rilascio destro incondizionato apriva menu anche senza pressione precedente; ora viene rilasciato solo un pulsante registrato o realmente premuto. La classe di menu classici `#32768` veniva riconosciuta come dialogo per il suo stile modale; ora ha precedenza la classificazione popup. Le coordinate relative alla finestra producevano spostamenti eccessivi durante il drag, mentre la posizione corrente del mouse perdeva campioni già accodati: il percorso finale usa le coordinate globali registrate nell'evento.

Queste prove confermano il percorso su Foto, non tutte le applicazioni o configurazioni di monitor. Non sono state ripetute in questo aggiornamento tutte le prove popup di Edge e Blocco note. Rimangono esclusi aumento della risoluzione guest, monitor virtuale, nuovi driver e accelerazione 3D. Un timeout di resize sblocca comunque l'input e ripristina la misura dell'ultima immagine disponibile.

## Geometria condivisa — primo passaggio: Metal e stato reale dei display

Il pacchetto ricompilato mostra Blocco note e il popup File attraverso il nuovo presenter Metal. La diagnostica registra completamenti GPU su Apple M4 per la superficie principale `790×547` e il popup indipendente `326×460`. Ingrandimento a `800×552` e ripristino a `790×547` producono immagini aggiornate; il menu File si apre e viene richiuso con Esc senza modificare i documenti. L'aggiornamento del worker cambia l'epoch e recupera la finestra già aperta, senza un comando di rilancio. Il frontend è stato poi riaperto normalmente senza diagnostica.

La query Rust del display rileva Microsoft Basic Display Driver con la sola modalità `800×600` a 96 DPI. La creazione D3D richiesta come HARDWARE riesce invece su Microsoft Basic Render Driver `1414:008C`, con flag adapter zero: il primo controllo che considerava soltanto SOFTWARE lo classificava erroneamente. La versione finale riconosce anche gli ID documentati e riporta `hardwareDevice=false`, `softwareAdapter=true`. Questo risultato conferma che la VM attuale non è stata trasformata in una VM accelerata dalla sola introduzione di Metal.

Il Mac espone tre monitor, tutti con scala 2: uno con backing `2940×1912` e due con backing `3840×2160`. I punti e i pixel sono raccolti separatamente. Il limite dei frame è stato portato a 8.388.608 pixel su entrambe le estremità per accogliere una superficie 4K; non è ancora stata verificata una finestra 4K reale né applicata una nuova topologia Windows.

Il QEMU Native3D dell'app precedente in `/Applications` non coincideva con il proprio manifest: era stato sostituito da una prova VirtioFS. Il QEMU originale è stato ritrovato nel backup della prova. La preparazione selettiva ha prodotto 27 artefatti coincidenti con tutti gli hash del manifest, conservando licenze/patch/metadati e senza importare agenti o sharing. La firma dell'eseguibile è valida e la richiesta di versione termina indicando QEMU `10.0.12`. Questo runtime è preparato nella cartella privata `.build/Native3D`, ma non è ancora incluso o selezionato dalla nuova app. Non è una verifica di boot Windows, 3D o multi-monitor.

Limiti emersi nella breve prova: un trascinamento dell'angolo tramite automazione non ha cambiato le dimensioni; il cambio di superficie Metal è stato verificato mediante ingrandimento/ripristino. Il primo click subito dopo il ripristino non ha aperto il menu e la traccia contiene un rifiuto del focus Windows; il click successivo lo ha aperto. Questi aspetti rimangono da risolvere nel lavoro sulla geometria e sul focus, senza dichiararli coperti dalla verifica del renderer. La prima compilazione ha richiesto correzioni dei tipi CGFloat/DXGI e dei flag Win32.

Sono state usate compilazioni e brevi prove nell'app reale, senza aggiungere batterie di test o benchmark. Firma del pacchetto verificata; guest incluso e guest compilato coincidono, SHA-256 `f5cd0f7117d876ff8b3d7f9a672858980b43398f2d18243ffdf1d45fd24b1e92`. Il trasferimento rimane CPU BGRA e non sono stati misurati miglioramenti di prestazione.

Prossimo passaggio dell'obiettivo ancora attivo: preparare rollback offline di disco/EFI/TPM prima di cambiare driver o runtime, integrare il backend grafico e il recupero del desktop, applicare monitor/DPI e sincronizzare geometria e resize continuo. La VM originale resta intatta.

## Desktop integrato, checkpoint e primo tentativo Native3D

Il desktop standard è stato avviato e usato nella finestra `Windows Desktop` della nuova app: immagini presentate da Metal, apertura di Esplora file, navigazione sul CD e conferma UAC. QEMU usa il socket VNC privato e `-display none`, senza una propria finestra Cocoa. I primi avvii hanno rivelato l'assenza delle mappe tastiera `en-us`; la confezione include ora `share/qemu/keymaps` e il percorso `-L` esplicito.

Prima del cambio grafico è stato creato e controllato un checkpoint offline APFS di sei file dopo l'arresto regolare di Windows, con disco, EFI, TPM e configurazione. Il driver ARM64 v0.3 è stato installato nella sola copia con gli undici hash attesi e catalogo riconosciuto come `Valid`; pnputil ha pubblicato `oem4.inf`. Nessuna modifica alle protezioni Windows o alle integrazioni della VM originale.

Il primo boot Native3D, configurato inizialmente con tre uscite, non ha prodotto un desktop utilizzabile: QEMU rimaneva vivo, il display RFB riportava `Display output is not active`, il broker non aveva pubblicato superfici native e il normale arresto Windows non terminava. Il campionamento dei processi mostrava attesa nel ciclo eventi e nessun worker grafico bloccato da terminare separatamente. Dopo autorizzazione dell'utente, sono stati conservati anche i file persistenti della VM sospesa, quindi QEMU è stato chiuso e la stessa copia è ripartita con il profilo standard. Questa seconda copia è un punto di recupero da arresto anomalo, distinto dal checkpoint offline precedente. Il rendering 3D rimane da verificare; la prossima configurazione usa una sola uscita.

Durante il lavoro gli artefatti `.build` erano scomparsi mentre la VM era viva. Il nuovo `RuntimeStore` conserva versioni separate nella cartella privata: il successivo avvio standard ha usato effettivamente QEMU e swtpm da `Runtimes/<hash>/`, con desktop nuovamente visibile e catalogo di 68 app. La lettura dei monitor è stata separata dalla creazione Direct3D; entrambe le richieste diagnostiche sono fuori dal ciclo di input del worker e la prova hardware non viene eseguita nella connessione normale.

Build Rust e Swift e verifica della firma completate; il guest compilato coincide con quello incluso nel pacchetto, SHA-256 `6734b4a1e737d4e824723b1474ec40f0fa940197ccf7124b2a463be59a3ab859`. Il nuovo guest è stato aggiornato dalla console e il catalogo è tornato disponibile. La prova successiva ha rilevato un errore di associazione di Blocco note, già presente nel guest: l'attivazione Shell può non fornire un PID né una nuova finestra. Il riconoscimento ora considera anche l'AppUserModelID del processo; dopo l'aggiornamento, un avvio dal catalogo ha mostrato una normale finestra Blocco note separata sul Mac. Questo conferma l'avvio osservato, non tutte le varianti di attivazione o il ripristino di ogni finestra preesistente. La console associa Command a Control, evitando che una scorciatoia Mac consumata dal menu tocchi il tasto Windows e apra Start.

Il profilo Native3D ora parte con un'uscita a `1280×800`; al collegamento del guest richiede tramite RFB la dimensione del monitor Mac primario. La richiesta è separata dalla visibilità della console e dal resize delle singole app. La presenza di questo codice non dimostra ancora la modalità applicata da Windows o DPI corretti. Non sono state aggiunte batterie di test. Monitor/DPI condivisi, drag sincronizzato e resize continuo restano da completare; la console di recupero non sostituisce questi requisiti.

## Native3D a singola uscita — risultati e limiti concreti

Il boot a singola uscita ha raggiunto il desktop Windows con il driver `Red Hat VirtIO GPU 3D controller`, a `2560×1080` e 96 DPI. La finestra di recupero Mac ha presentato una superficie nativa `2560×1080` tramite Metal su Apple M4. Il broker ha pubblicato quattro superfici, con tre conferme e una ancora visualizzata, senza copie CPU nel broker. Il click ha aperto Esplora file e la navigazione sul CD ha aggiornato l'immagine. Il frontend è stato riconnesso alla stessa VM senza riavviare Windows. Una normale finestra Blocco note è stata poi mostrata separatamente, con il trasporto BGRA/WARP già esistente: questo percorso continua a copiare i pixel.

Questa prova non completa l'integrazione grafica. Il monitor annuncia `2940×1912`, ma Windows conserva `2560×1080`; il nuovo `display_configure`, eseguito fuori dal ciclo di input, ha ricevuto `DISP_CHANGE_FAILED (-1)` durante CDS_TEST. La modalità annunciata non va quindi descritta come applicata. La richiesta separata di creazione Direct3D non ha fornito un esito entro il timeout del frontend: l'identità hardware di quel dispositivo non è confermata da questo probe. Catalogo e cattura sono rimasti disponibili.

È emerso anche un limite del desktop protetto: il backend nativo mostrava lo sfondo attenuato di UAC senza il dialogo. Non è stata confermata alla cieca né disattivata la protezione. Windows è stato arrestato regolarmente; il profilo standard ha mostrato il dialogo UAC e consentito l'aggiornamento guest, quindi è stato eseguito un nuovo boot nativo. Questo rende il profilo standard necessario al recupero amministrativo finché il difetto non viene corretto.

Il guest aggiornato separa anche le code di monitor e probe Direct3D, così una prova hardware in corso non rifiuta le letture dei display con `Diagnostics already running`. Build Rust/Swift e firma verificate; il guest incluso coincide con quello compilato, SHA-256 `6f43b263ff8959760ab8923b596271510d5bb8430a8af0a506296b63ad669ba3`. Nessuna nuova batteria di test o benchmark.

### Modalità applicata e resize oltre il vecchio limite

Alla successiva riconnessione della stessa VM, `display_configure` ha applicato `2940×1912`, coincidente con i pixel di backing del monitor Mac primario. Windows ha scelto 120 DPI: la scala non coincide ancora con quella Mac 2×. Il probe Direct3D ha restituito `hardwareDevice=true`, `softwareAdapter=false`, adapter `Red Hat VirtIO GPU 3D controller`, ID `1AF4:1050` e feature level `11_0`. Il primo fallimento di configurazione durante il boot non dimostrava quindi l'assenza della modalità; il frontend ora prevede pochi tentativi distanziati. Questo non è ancora un collaudo di tutti i boot o dei monitor aggiuntivi.

Il tracking implicito AppKit delle finestre principali senza barra intercettava il primo gesto e restituiva la stessa misura. Con i bordi espliciti, Blocco note è passato da `986×683` a `1086×683`, quindi a `1186×733`, con rettangolo Mac e dimensione Windows finale concordanti. Il menu File si è aperto dopo il resize ed Esc lo ha chiuso, senza modificare documenti. La prima variante del coalescer attendeva un timer prima di inviare il primo campione: il gesto rapido non ha dimostrato aggiornamenti intermedi. La versione successiva invia subito il primo campione e limita quelli seguenti a una richiesta in corso e una misura in attesa, con timer nei modi comuni del run loop.

Sono emersi difetti grafici sostanziali dopo il cambio di modalità e l'uso delle finestre: la console completa è rimasta nera mentre il broker riportava `closed=true`, nessuna nuova pubblicazione e richieste rifiutate. Il log contiene `capture closed: resource identity/bound`. Il componente di riferimento conserva risorse distrutte come tombstone in una tabella limitata e non ammette il riuso degli identificatori; gestione delle risorse e recupero dello stream devono essere corretti prima di considerarlo un backend ordinario affidabile. Le catture delle singole finestre hanno inoltre mostrato artefatti nella barra e nelle trasparenze del menu. Il presenter Metal e la sola enumerazione hardware non risolvono questi limiti.

Il comando `Recovery Display` è stato azionato nell'app mentre la console nativa era nera. Ha arrestato Windows regolarmente, avviato il display standard e mostrato nuovamente desktop e catalogo di 68 app. La preferenza Native3D è conservata; solo il flag di recupero è attivo. Il recupero non ha richiesto modifiche manuali alla configurazione o un ulteriore spegnimento forzato. L'obiettivo complessivo resta aperto: ciclo delle risorse grafiche, scala DPI, posizione condivisa delle finestre e più monitor richiedono ancora lavoro.

La verifica mirata finale del coalescer è stata eseguita sul display di recupero: Blocco note è passato da `690×547` a `740×547`. La traccia registra la nuova misura Mac in `resize_live_requested` prima della richiesta finale e del termine del gesto; Windows conferma poi `740×547`. La versione precedente leggeva `content.bounds` ancora alla misura vecchia durante il tracking: il mittente ora deriva il contenuto dal rettangolo richiesto della finestra e scarta il campione iniziale invariato. Questa prova conferma l'invio durante il gesto e la riconciliazione finale, senza misurare la fluidità dei frame intermedi. Il menu File è tornato visibile dopo il resize ed Esc lo ha richiuso. Nessun documento modificato, nessuna nuova infrastruttura di test.

Il pacchetto finale è stato riaperto normalmente, senza variabili diagnostiche, e ha recuperato la stessa finestra Blocco note a `740×547` nella VM rimasta accesa. Il profilo di recupero resta selezionato per lasciare disponibile l'app mentre vengono corretti i difetti del backend nativo; il desktop standard è ancora `800×600`.

## Fine dei contesti grafici e durata delle immagini native

Un nuovo boot nativo ha applicato automaticamente `2940×1912`, verificando anche i pochi tentativi di configurazione introdotti nel passaggio precedente. Il runtime diagnostico iniziale ha pubblicato oltre 260 immagini del desktop. Dopo l'apertura di Blocco note, il broker riportava `closed=true` con `rejected=0`: i soli precedenti errori di registrazione non spiegavano tutte le chiusure. Il codice chiudeva la cattura anche alla normale fine del contesto attivo. L'arresto regolare di questa prova non è terminato; con l'autorizzazione già ricevuta per recuperare la stessa copia, sono stati conservati nuovamente i file persistenti a VM sospesa e chiuso QEMU. Anche questo è un punto di recupero da arresto anomalo, non un checkpoint pulito.

Il nuovo renderer/server conferma la raccolta del processo figlio prima di ritirarne il contesto. Il Mac copia l'immagine nativa in una texture propria tramite Metal e libera la superficie condivisa al completamento GPU: non trattiene più l'ultima immagine del produttore in attesa del successore. Non sono stati aumentati i limiti delle tabelle o disattivati controlli di completamento, identità o import. Un solo controllo C mirato ha rifiutato un figlio ancora vivo e confermato la raccolta dopo la sua terminazione; compilazioni C/Swift e firma del pacchetto sono riuscite.

Nella prova successiva nell'app reale, dopo il boot e l'apertura di Blocco note sono state osservate 606 immagini native pubblicate e confermate, nessuna in attesa, 17 contesti ritirati con conferma, `rejected=0` e `closed=false`. Metal su Apple M4 ha completato la lettura con `nativeGPUCopy=true`. Il desktop continuava ad aggiornarsi dopo l'apertura delle finestre, invece di chiudere il broker. Il successivo comando `Recovery Display` ha arrestato regolarmente la VM nativa e riavviato il display standard.

Restano difetti visivi sostanziali: Blocco note aveva parti mancanti nella cattura della singola finestra, e anche la console nativa mostrava sfondo nero e testo incompleto nel menu. La correzione della durata delle risorse non dimostra quindi un rendering ordinario corretto. Desktop protetto, riuso/esaurimento delle identità, DPI, posizioni condivise e più monitor restano da completare. Il profilo standard rimane selezionato per lasciare disponibile l'app. Nessuna modifica ai documenti, alla VM originale o alle protezioni Windows.

Il pacchetto ricompilato è stato aperto normalmente senza diagnostica: catalogo di 68 applicazioni e Blocco note a `790×547`, con documento, schede e menu nuovamente leggibili nel display di recupero. Tutti i 27 artefatti grafici corrispondono al manifest aggiornato; la firma del pacchetto è valida. Il guest Rust non è cambiato in questo passaggio.

## Preferenza UAC della copia di sviluppo

Su richiesta esplicita dell'utente, nella sola copia Windows usata da Perpendicular è stata selezionata «Non notificare mai» nel pannello Controllo dell'account utente e confermata l'ultima richiesta UAC. Il pannello è stato chiuso e riaperto: il cursore era ancora sul livello minimo e il testo riportava «Non notificare mai». Non è stato necessario riavviare. Si tratta di una modifica una tantum della VM; nessun installer o guest tool viene modificato per applicarla ad altre macchine. Non è stata eseguita la diversa modifica `EnableLUA=0` al registro. La VM originale resta intatta.

## Display reale, esperimenti scartati e prerequisiti della nuova strada

I tentativi DOD con il runtime QEMU 10 non hanno prodotto un display utilizzabile: Windows continuava a selezionare il pacchetto 3D con codice 43; il cambio a caldo ha provocato un riavvio interno e il successivo output era inattivo. Questo non identifica una causa precisa del riavvio. La preparazione DOD a freddo è terminata nel display RAMFB, ma il successivo candidato QEMU 11 non è stato avviato. Le sue riuscite storiche non sono evidenza di affidabilità della nuova app. I preparatori sono stati ritirati dal codice ordinario, conservandoli solo nella directory privata di build. Rimane un breve resoconto dell'esperimento, senza importarne il codice nella nuova base.

La copia è tornata al QEMU standard con RAMFB, senza finestra Cocoa QEMU. La preferenza privata è Standard; il dispositivo della VM già accesa non è stato cambiato. I checkpoint offline restano conservati e la VM originale non è stata modificata. La preparazione DOD ha disabilitato Fast Startup e segnalato la rimozione del pacchetto 3D selezionato: prima di una nuova prova Native3D va verificato/reinstallato il pacchetto, non basta il selettore host. I vecchi dispositivi display non presenti non dimostrano che il loro driver sia attualmente in uso.

L'inventario nativo SetupAPI ha risposto separatamente dalla query dei monitor, riportando i dispositivi VirtIO precedenti come non presenti. Il rapporto PowerShell completo delle vecchie integrazioni continua invece a raggiungere il timeout: non è considerato riparato e non entra nel collegamento ordinario. Il limite di tempo e il drenaggio dei due flussi ne limitano l'impatto sul resto del worker.

Build Rust ARM64 e Swift 6 riuscite, firma del pacchetto verificata. Guest compilato e incluso coincidono: SHA256 `91fa9cece7eecc2002eea7d6f37f4cbb093849159d34e32671b3ad9773b0f24f`. Il servizio è stato aggiornato dalla console elevata senza reinstallare integrazioni precedenti o driver. L'app riaperta normalmente si è riconnessa e ha mostrato 68 applicazioni e lo stato effettivo `800 × 600, 100% scale`. La risorsa Display2D è assente dal pacchetto.

Tre controlli temporanei hanno verificato la trasformazione del primario Retina, l'inversione Y con origini negative/nonzero e il rifiuto di risoluzione/DPI o campi non validi. Non sono prove VM o multimonitor. Il nuovo osservatore guest invalida lo stato tramite broadcast display/impostazioni, senza enumerare adapter nel ciclo input; l'effettiva riconfigurazione di un display dinamico resta da provare. La corrispondenza non viene dichiarata per RAMFB e non abilita ancora la sincronizzazione delle posizioni.

Durante l'uso della console l'immagine RFB è rimasta ferma mentre i tasti raggiungevano Windows. La riapertura ha mostrato la riga aggiornata; una riga incompleta è stata cancellata senza eseguirla. La lettura ora richiede un'immagine completa dopo inattività e riconnette se il server non risponde; il successivo aggiornamento guest è stato visibile senza riaprire il frontend. Questa breve osservazione non certifica la stabilità generale della console, che resta un percorso di manutenzione.

La lettura della copia ha restituito Windows `Professional`. FreeRDP 3.32.2 è stato compilato separatamente per ARM64 da sorgente ufficiale con hash verificato, usando OpenSSL@3 esistente e aggiungendo solo CMake come strumento di build. Il client di prova C crea/configura il context senza rete; nessuna connessione RDP, cambio credenziali o attivazione dell'accesso remoto è stato eseguito. Restano aperti sessione RDP corretta, monitor/DPI applicati, WGC, input e riconnessione in quella sessione. Non è una sostituzione già verificata del backend né una prova RemoteApp.

Blocco note è stato aperto dal catalogo del pacchetto finale, con contenuto e controlli Windows leggibili nella propria finestra Mac. Il menu File non si è aperto nei due click della breve prova mentre era ancora aperta la console amministrativa: attivazione/input in questa condizione non sono considerati superati. Nessun documento è stato modificato. La lettura del registro ha confermato RDP inizialmente disabilitato (`fDenyTSConnections=1`); l’utente ha poi autorizzato esplicitamente la prova nella sola copia.


## Preparazione della prova RDP con consenso dell'utente

Dopo l'autorizzazione esplicita sono stati compilati e installati il guest con selezione della sessione per ownerSid e l'inventario RDP nativo. Build Rust ARM64 e Swift 6 riuscite; SHA256 guest `debed1829950452a2f77d2360c20d9d55c90509f6c62e5ef4de3f38adea6f4ea`. Il servizio aggiornato si è riconnesso nella sessione console 1 dello stesso utente.

Lo script locale è terminato mostrando NLA/TLS e regola limitata al Mac. La lettura nativa tramite collegamento autenticato ha poi confermato `Professional`, `fDenyTSConnections=0`, `nla=1`, `securityLayer=2` e un solo certificato valido nello store Remote Desktop. SHA256 è calcolato sul DER pubblico: nessuna chiave privata esportata. Il forward temporaneo QEMU è stato verificato su `127.0.0.1:13389`, verso TCP3389 della sola copia; i dati per rimuoverlo sono nella cartella privata.

Le librerie C, il probe e il dialogo Swift sono stati compilati. Il controllo locale del probe configura il context senza connessione. La finestra `Connetti a Windows` è stata aperta con campo password sicuro e account letto dal guest; l'accesso attende l'inserimento locale da parte dell'utente. A questo punto non è ancora stata eseguita una connessione autenticata: monitor/DPI RDP, WGC e ritorno effettivo alla console non sono dichiarati verificati. Il desktop della VM resta attualmente RAMFB a 800×600/96 DPI. Nessun nuovo driver, cambio di password o indebolimento di NLA/Secure Boot.

Il primo tentativo avviato dal dialogo non ha completato la prova e non ha applicato il nuovo monitor. La versione iniziale mostrava soltanto un errore generico, quindi non gli viene attribuita una causa di password, certificato o driver. La verifica separata del solo trasporto, senza inviare credenziali, ha ottenuto la selezione NLA e una sessione TLS1.2/AES256-GCM-SHA384 con SHA256 del certificato coincidente con il pin del guest. Il client aggiornato riporta ora il codice numerico FreeRDP e registra soltanto stati ammessi, senza dati di autenticazione; un nuovo accesso resta subordinato all'inserimento locale della password. RDPEDISP e cattura WGC nella sessione remota rimangono non verificati.

L'utente ha poi chiarito che l'account Windows è sempre stato senza password. La prova richiede quindi una credenziale locale utilizzabile prima di proseguire: non sono stati tentati accessi con password vuota, modificati account o ridotte le protezioni NLA e sulle password vuote. Il dialogo di connessione è stato chiuso. L'eventuale nuova password deve essere impostata direttamente dall'utente nella sola copia Windows; la scelta del percorso resta aperta. Il trasporto TLS verificato non dimostra un accesso autenticato riuscito.
