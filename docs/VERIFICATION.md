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
