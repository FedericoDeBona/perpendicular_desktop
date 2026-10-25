# TODO — feature e correzioni

Ultimo aggiornamento: **25 ottobre 2026**. Responsabile dell'aggiornamento: l'agente che lavora al progetto, a ogni cambiamento pertinente, come richiesto in [AGENTS.md](../AGENTS.md).

Questo è l'elenco operativo delle attività. [KNOWN_ISSUES.md](KNOWN_ISSUES.md) conserva diagnosi e dettagli dei difetti, [VERIFICATION.md](VERIFICATION.md) le evidenze e i fallimenti, [RESTART_PLAN.md](RESTART_PLAN.md) la base operativa. Gli ID qui sotto sono stabili e rimandano ai problemi esistenti: non sostituiscono né duplicano il registro dei difetti.

**Passaggio attuale: implementazione esplicitamente richiesta di TODO-019, catalogo unico e impostazioni VM.** Le precedenti revisioni della lista erano soltanto documentali. Le altre attività restano nei rispettivi stati; la prova di avvio con1 GB è riservata all'utente, non eseguita automaticamente.

## Regole di aggiornamento e stati

Leggere questa lista a ogni ripresa dopo registro e piano. Aggiornarla quando cambia requisito, priorità, implementazione, verifica, distribuzione o blocco; nello stesso passaggio aggiornare il problema collegato e aggiungere le evidenze al diario. Non eliminare le voci concluse, non confondere una ricerca con una prova reale e non segnare come distribuito ciò che funziona soltanto in un clone.

| Stato | Significato |
| --- | --- |
| DA FARE | Richiesto, non completato; eventuale fattibilità ancora da verificare. |
| IN CORSO | Lavoro effettivamente iniziato, con prossimo risultato osservabile indicato. |
| BLOCCATO | Ostacolo concreto: indicare causa e condizione per ripartire. |
| FATTO | Criterio di completamento verificato nel perimetro dichiarato, con evidenza e stato della distribuzione. |
| IMPOSSIBILE NEL PERIMETRO INDICATO | Vincolo dimostrato per piattaforma/versioni/condizioni esplicite; spiegare e avvisare l'utente. Non equivale a «non ancora provato». |
| RINVIATO / RITIRATO | Non attivo per decisione esplicita o valutazione conclusa; conservare motivo e storia. |

Ogni voce deve conservare stato corrente, requisito, ciò che è realmente noto, prossimo passo e criterio di completamento. I limiti di osservabilità vanno dichiarati: un campo mancante non vale zero. Nessuna voce viene dichiarata globalmente impossibile con la sola ricognizione attuale.

## Quadro corrente

Priorità 1–4 corrispondenti alla richiesta iniziale dell'utente; TODO-017/018 aggiungono l'integrazione dei comandi Mac e degli appunti richiesta successivamente. Le altre righe conservano difetti e risultati già noti. Non iniziare automaticamente tutte le attività insieme.

| ID | Attività | Stato corrente | Riferimenti / dipendenze |
| --- | --- | --- | --- |
| TODO-001 | Schermi Windows N+1 | BLOCCATO nel driver/runtime corrente | WIN-003; serve prima una seconda uscita reale protetta. |
| TODO-002 | Geometria, input e finestre Mac/Windows 1:1 | DA FARE; correzioni parziali precedenti | GFX-006, WIN-001/002/003; estensione multischermo dipende da 001. |
| TODO-003 | Stessi file utente su Mac e Windows, senza copie | DA FARE; virtio-fs candidato, combinazione non qualificata | Backend macOS, client ARM64 firmato, compatibilità RAM. |
| TODO-019 | Catalogo unico, recenti in alto e impostazioni VM al posto dei processi | IN CORSO: implementato/installato0.2.1, qualifica UI parziale | Catalogo osservato; configurazione verificata su fixture; verifica interattiva pannello interrotta da errore CUA. |
| TODO-017 | Scorciatoie e comandi Mac nelle app Windows e in Perpendicular | DA FARE per completamento e qualifica main; base parziale presente | Cmd+C/V/X/T/Q e altri comandi comuni; destinazione secondo focus/contesto. |
| TODO-018 | Copia/incolla di testo e file Mac ↔ Windows | DA FARE; testo già implementato e provato storicamente, file mancanti | Entrambe le direzioni, desktop e singole app; collegamento con TODO-003. |
| TODO-004 | Tutti i tempi della pipeline grafica, desktop e singola app | DA FARE; strumentazione esistente incompleta | Copertura per stadio, correlazione e limiti di misura. |
| TODO-005 | Misurare e migliorare disco/I/O quando utile | DA FARE | Meccanismi concreti identificati, non provati sul sistema. |
| TODO-006 | Misurare CPU e costo della VM sempre accesa | DA FARE | Host e guest distinti; campionamento ARM virtuale da accertare. |
| TODO-007 | Misurare GPU e costo della traduzione grafica | DA FARE | Tempi Metal/ETW candidati; contatori effettivi da accertare. |
| TODO-016 | Correggere la sincronizzazione GPU Wait/Signal | BLOCCATO per una soluzione protetta qualificata; difetto aperto | GFX-007; segnalazione upstream nell'issue8, distinta dagli esperimenti ritirati. |
| TODO-008 | Catture complete, aggiornate e risorse grafiche rilasciate | DA FARE | GFX-001/003/004, difetti aperti. |
| TODO-009 | Arresto/riavvio affidabile e gestione degli errori | DA FARE | SYS-001. |
| TODO-011 | Qualificare launcher e riconnessione delle singole app sulla main | DA FARE; correzioni nel clone | APP-002, WIN-001/002. |
| TODO-012 | RAM dinamica reale con Windows protetto | FATTO nel perimetro documentato | SYS-003; ciclo Native3D 4→2→4 GiB, unplug parziale ammesso. |
| TODO-013 | Base unica main/default e pulizia autorizzata | FATTO | App 0.2.0 + IoT principale; restano difetti grafici. |
| TODO-014 | Creality/OpenGL | RINVIATO dall'utente | APP-001. |
| TODO-015 | IVSHMEM e vecchi driver candidati | Valutazione FATTA / esperimenti RITIRATI | TRN-001, GFX-002/005; il difetto sync GFX-007 resta TODO-016. |

Vincoli comuni: preservare `/Applications/Perpendicular.app` e la IoT principale; **Secure Boot e Code Integrity attivi, TESTSIGNING disattivato nella soluzione finale**. Nessun driver non accettato con queste protezioni costituisce un completamento. La VM deve poter restare accesa in background. Dischi, credenziali e tracce private restano fuori Git. Preferire il controllo tramite guest tool, evitando uso superfluo del computer use.

## TODO-001 — Schermi N+1

**Stato: BLOCCATO nella base corrente.** Requisito: N monitor Windows corrispondenti ai monitor Mac, più l'area Windows riservata accessibile da «Apri Windows», con comandi diagnostici per le uscite. Non equivale a isolare desktop o processi Windows.

Il [limite WIN-003](KNOWN_ISSUES.md#win-003--monitor-n1-e-drag-fra-scale-diverse) è già documentato: driver ufficiale con `MAX_CHILDREN=1`, seconda GPU 3D senza hotplug e rifiutata dal runtime corrente anche all'avvio. Cambiare il solo `max_outputs` non risolve. La base offre una sola uscita; nessuna affidabilità multischermo è stata verificata.

**Prossimo passo:** individuare supporto multischermo effettivo in un driver ARM64 accettato dalle protezioni oppure nel supporto di più adattatori del runtime. Prima milestone: due uscite indipendenti realmente enumerate e utilizzabili da Windows. Poi mappatura stabile delle identità Mac/Windows e dell'uscita riservata, collegamento/scollegamento monitor e scale diverse.

**Fatto quando:** N+1 reale nell'app principale, con finestra e relativo dialogo trasferibili fra schermi di scala diversa mantenendo contenuto, posizione e input. Non contare uscite fittizie o soli ACK di configurazione. Un eventuale limite del percorso scelto va riportato con versioni e alternative, senza ridurre le protezioni.

## TODO-019 — Catalogo unico e impostazioni VM

**Stato: implementato e distribuito nella0.2.1; qualifica interattiva completa ancora IN CORSO.** Catalogo unico osservato nell'app installata, con recenti in alto e tutte le app; rimossi pannello processi, accessi e gestione UI associata. Impostazioni disponibile nella barra laterale, menu e Cmd+virgola. Chiusura del canale CUA durante l'apertura del pannello impedisce di qualificare tutti i controlli; l'app rimane viva/collegata. Nessun nuovo difetto del prodotto dimostrato.

CPU, RAM all'avvio (anche1024 MB), RAM automatica, limite totale, minimo in background e riserva devono essere modificabili. Mostrare separatamente impostazioni salvate per il prossimo avvio e valori attuali. Le modifiche salvate a VM accesa restano in un file privato separato: applicazione a machine.json soltanto dopo arresto confermato e prima del nuovo avvio. Preservare identità, disco, EFI/TPM, token, campi sconosciuti e runtime protetto; nessun riavvio automatico o prova a1 GB da parte dell'agente. Riassociare controller RAM e callback al controller VM ricaricato.

**Verificato:** build e firma, store con salvataggio differito/validazione/preservazione campi, controller reale su fixture temporanea: nessuna applicazione con PID vivo e stato non verificabile; applicazione della configurazione1 GB solo a stato spento, senza boot. Sulla main:47 app, nuovo catalogo visibile, stesso PID Windows, machine.json e binari guest/runtime conservati, nessuna modifica in attesa. **Prossimo passo:** completare soltanto la verifica interattiva del pannello quando lo strumento UI torna disponibile, senza ripetere i controlli già riusciti. **Fatto quando:** anche controlli/salvataggio nel pannello installato verificati. L'utente può effettuare il boot a1 GB; questo resta distinto e non è anticipato dall'agente. Il funzionamento RAM già qualificato di TODO-012 non qualifica quel boot. [Evidenze](VERIFICATION.md#25-ottobre--catalogo-unico-e-impostazioni-cpuram).

## TODO-002 — Finestre native Mac 1:1 con le finestre Windows

**Stato: DA FARE; correzioni parziali nel clone, qualifica main incompleta.** Il sospetto dell'utente sulle dimensioni differenti è un'ipotesi plausibile, non la causa già dimostrata di tutti i guasti. Catture incomplete e superfici stale hanno voci distinte.

La main ha ancora [GFX-006](KNOWN_ISSUES.md#gfx-006--risoluzione-e-dpi-errati-dopo-installazione-a-caldo): ultimo desktop osservato 2048×1152 e richiesta di risoluzione non confermata. Il mapping `SharedDisplay` attuale riguarda il monitor primario. Drag e attesa resize hanno correzioni precedenti [WIN-001/002](KNOWN_ISSUES.md#win-001--spostamenti-casuali-nel-drag-delle-finestre-individuali), non una qualifica generale sulla IoT main.

**Prossimo passo:** risolvere/confermare prima la geometria effettiva del percorso attivo, anche su un solo monitor; questo non deve aspettare tutto N+1. Definire un'unica trasformazione fra punti AppKit, pixel Retina, coordinate e DPI Windows, aree di lavoro, client e cornice, con origini degli assi esplicite. Non ottenere un'apparenza corretta con uno stretching che lascia errato l'input.

Conservare dimensione percepita 1:1, controlli Windows sulle finestre principali, popup/tooltip collegati al proprietario e controlli Mac sui veri dialoghi. Spostamento, resize al rilascio con anteprima locale, frame confermato e coordinate del mouse devono riferirsi alla stessa geometria. Includere focus, minimizzazione/ripristino e passaggio fra schermi; l'estensione multischermo dipende da TODO-001.

**Fatto quando:** breve percorso reale sulla main con spostamento, resize, click su bordi/controlli e apertura di dialogo corretti, poi trasferimento fra scale diverse appena disponibili due uscite. Nessuna modalità segnalata pronta prima di conferma Windows e frame pertinente. Evidenze collegate alle singole voci WIN/GFX.

## TODO-003 — Gli stessi file Mac anche in Windows

**Stato: DA FARE; fattibilità della combinazione completa non verificata.** Requisito: Desktop/Scrivania, Documenti, Download, Immagini, Musica, Video e le altre cartelle utente devono esporre gli stessi file del Mac. Creazioni, modifiche, rinomine ed eliminazioni devono operare sull'unico contenuto condiviso, senza cartelle duplicate o sincronizzazione. Anche i percorsi standard usati dalle app e dai dialoghi Windows devono puntare alle cartelle corrette; un drive condiviso separato non completa il requisito.

**Conferma tecnica:** virtio-fs consente accesso diretto a un albero di directory dell'host senza Samba/SMB. Windows richiede un driver VirtIO e un servizio basato su WinFsp, come descritto nella [documentazione virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows/wiki/Virtiofs:-Shared-file-system). Non è una funzione già attiva nel progetto. I manifest upstream attuali includono [viofs e virtiofs.exe per Win11 ARM64](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/win11_arm64.ddf); il maintainer conferma [WinFsp ARM64](https://github.com/orgs/winfsp/discussions/594). Questi riferimenti dimostrano supporto nel progetto upstream, non disponibilità/firma/caricamento di uno specifico pacchetto nella nostra IoT.

Lato Mac esiste un [backend macosvirtiofsd per QEMU](https://github.com/mheese/macosvirtiofsd), il cui autore riporta prove con guest Linux su Apple Silicon e richiede vhost-user e RAM condivisa. È un candidato da valutare, non una combinazione Windows già qualificata. Non trasferire automaticamente al nostro QEMU/HVF le capacità di Apple Virtualization.framework o di altri hypervisor.

**Prossimi passi, in ordine:**

1. Identificare una versione concreta del backend macOS e un pacchetto viofs/WinFsp ARM64 accettato da Secure Boot/CI. Leggere limiti e licenze; non assumere che basti compilare il driver o che tutte le ISO VirtIO contengano gli stessi binari.
2. Risolvere la compatibilità della memoria: il candidato vhost-user richiede backing condiviso, mentre il [reclaim virtio-mem attuale](../memory/README.md) supporta backing anonimo privato e rifiuta quello condiviso/file-backed. Valutare quali regioni debbano essere condivise e come preservare balloon/hotplug; non sostituire globalmente il backend RAM dichiarando ancora valido TODO-012. Questa è una dipendenza concreta, non una prova d'impossibilità di virtio-fs in generale.
3. Progettare mount stabile e reindirizzamento delle cartelle note Windows verso i percorsi host. Il disco di sistema Windows, registro e componenti installati restano necessari: non sono copie dei documenti Mac. Inventariare anche dati utente in percorsi non standard, senza lasciarli duplicati per omissione.
4. Definire permessi macOS/TCC, eventuali file iCloud non ancora locali, accessi simultanei, locking, notifiche, salvataggi tramite rename, nomi/case, link e metadati. Dichiarare le differenze APFS/Windows rilevanti alle app; stesso file non implica identiche semantiche NTFS. Un collegamento di trasporto come virtio-vsock, da solo, non fornisce un filesystem.

**Fatto quando:** sulla main protetta un documento aperto da entrambe le parti è lo stesso contenuto host, modifiche/rinomine visibili senza copia o sincronizzatore, cartelle standard e salvataggi delle app instradati correttamente, riavvio/riconnessione non creano cartelle alternative, RAM dinamica preservata. Prima prova futura limitata a una cartella temporanea e un file sacrificabile; poi estendere al requisito completo. Se il percorso senza SMB non è praticabile nel perimetro, documentare il blocco e avvisare prima di proporre un'alternativa: nessuna sostituzione silenziosa con copie o Samba.

L'integrazione dei percorsi condivisi deve comprendere anche i riferimenti ai file negli appunti di TODO-018: un percorso Mac non diventa utilizzabile in Windows con il solo cambio della stringa. La condivisione dello stesso contenuto e il comando esplicito dell'utente per copiarlo in una destinazione sono operazioni distinte.

## TODO-017 — Comandi e scorciatoie Mac nelle app Windows

**Stato: DA FARE per completamento e qualifica nell'app principale; implementazione parziale già presente.** Requisito: usare le abituali scorciatoie Mac anche nelle finestre Windows, con menu e tastiera coerenti, senza dover cambiare abitudini passando da un sistema all'altro.

Ricognizione del codice: `ApplicationContent.swift` intercetta combinazioni Command, inoltra molti comandi come Control, gestisce copia/taglia/incolla e traduce Cmd+Q in Alt+F4. `App.swift` ha il comando Quit di Perpendicular; il desktop usa un altro percorso input in `DesktopWindow.swift`. La [verifica del22 ottobre](VERIFICATION.md#22-ottobre--delete-scorciatoie-mac-e-appunti-di-testo) copre un giro di testo e alcuni tasti, non tutte le scorciatoie né la main attuale. Alt+F4 sulla finestra non dimostra di aver chiuso tutta l'app Windows e i suoi processi.

**Comportamento richiesto e convenzione operativa da qualificare:**

| Comando Mac | Risultato atteso nel contesto attivo |
| --- | --- |
| Cmd+C / Cmd+X / Cmd+V | Copia, taglia e incolla dell'app Windows con appunti accessibili anche dal Mac, secondo TODO-018. |
| Cmd+T | Nuova scheda nell'app Windows che supporta le schede; rispettare il contesto dell'app e i comandi della UI Mac quando è quella ad avere il focus. |
| Cmd+A / Cmd+Z / Cmd+Shift+Z | Seleziona tutto, annulla e ripristina secondo il comando equivalente dell'app. |
| Cmd+S / Cmd+O / Cmd+N / Cmd+F | Salva, apri, nuovo e cerca dove supportati dall'app. |
| Cmd+W | Chiude scheda/documento/finestra secondo il contesto, conservando i dialoghi di salvataggio. |
| Cmd+Q | Nella singola app Windows, richiesta regolare di uscita dell'app; nel launcher/UI di Perpendicular, uscita da Perpendicular. La richiesta comprende entrambi i contesti: nessuno deve risultare irraggiungibile perché l'altro intercetta sempre la combinazione. |

La distinzione per focus è la convenzione proposta per rendere concreta la richiesta; la politica di eventuale uscita combinata da app Windows e Perpendicular non è stata specificata. Prima dell'implementazione renderla esplicita, insieme al comportamento nel desktop completo, dove il contenitore Mac e l'app Windows in primo piano sono due destinazioni possibili. Non dedurre che Cmd+Q debba arrestare Windows: resta il requisito della VM accesa in background. Per l'uscita da Perpendicular definire anche chi mantiene il controllo RAM in background e il ripristino del collegamento alla riapertura.

**Prossimo passo:** mappare comandi, focus e menu nei due percorsi desktop/singola app; riusare quanto già presente. Distinguere uscita dall'app Windows, chiusura della sua finestra e uscita dal frontend. Invio unico del comando, corretti press/release, modificatori rilasciati al cambio focus; preservare commutazione app e altre scorciatoie di sistema Mac. La chiusura deve lasciare operativi Salva/Annulla e non diventare una terminazione forzata implicita.

**Fatto quando:** breve percorso sulla main con Cmd+C/V, Cmd+T in un'app con schede, Cmd+W e Cmd+Q nei contesti previsti, inclusa cancellazione di un'uscita con documento modificato. Risultato osservabile nella vera app Windows e nello stato di Perpendicular/VM; nessun comando duplicato, destinatario errato o tasto rimasto premuto. Verifiche future, non eseguite in questo passaggio.

## TODO-018 — Appunti trasversali: testo e file Mac ↔ Windows

**Stato: DA FARE per completamento; testo parziale già implementato, file da implementare.** Requisito: copiare/tagliare/incollare testo e copiare/incollare file nelle due direzioni, da app Mac verso Windows e viceversa, attraverso i comandi abituali. Coprire sia le finestre individuali sia il desktop Windows completo.

**Stato noto:** `ApplicationWindow.swift` e `guest/src/windows/clipboard.rs` trasferiscono testo Unicode su richiesta, fino a256 KiB UTF-8, con controlli di focus, risposta tardiva e cambiamento degli appunti Mac. Il [giro reale del22 ottobre](VERIFICATION.md#22-ottobre--delete-scorciatoie-mac-e-appunti-di-testo) ha verificato Mac→Blocco note→Mac, Unicode e Delete nella base di allora. Non è una qualifica della IoT main attuale. Il codice non trasferisce file; il reader RFB del desktop riceve e scarta il messaggio clipboard invece di collegarlo agli appunti Mac. La capability `clipboard=true` del guest non dimostra supporto ai file o parità dei due percorsi.

**Prossimi passi:**

1. Completare e qualificare il testo nei due percorsi, incluse copie da menu/azione dell'app oltre al solo intercettare Cmd+C, Unicode, righe multiple e passaggio di focus. Definire eventuali limiti visibili senza sostituire gli appunti con dati vecchi o parziali; evitare aggiornamenti che si rimbalzano fra i sistemi.
2. Esporre selezioni di file/cartelle compatibili con Finder, Explorer e i dialoghi delle app. Se il contenuto è condiviso da TODO-003, tradurre i riferimenti ai percorsi effettivamente accessibili. Per file residenti soltanto su uno dei due sistemi prevedere un trasferimento reale su richiesta con destinazione esplicita; non fingere che un percorso inaccessibile costituisca una copia riuscita.
3. Gestire almeno selezioni multiple, cartelle, nomi Unicode, conflitti di nome, copia interrotta/disconnessione ed errori utilizzabili. Per i file grandi evitare caricamento integrale negli appunti o nel singolo messaggio; per file virtuali/promessi fornire il contenuto quando richiesto o dichiarare il limite. Il semplice testo del percorso non basta come supporto file.
4. Tenere distinto copia da spostamento/taglia: nessuna cancellazione del file sorgente prima del completamento confermato. Preservare i dati già presenti e i nuovi appunti copiati dall'utente nel frattempo; non registrare i contenuti degli appunti nei log.

L'interfaccia deve offrire la stessa operazione da menu e da tastiera. Drag-and-drop non viene considerato automaticamente completato dal supporto agli appunti: potrà essere aggiunto come requisito distinto. La condivisione di TODO-003 non è sostituita da un sincronizzatore o da copie periodiche.

**Fatto quando:** sulla main protetta una breve operazione per direzione copia testo fra app reali e trasferisce un piccolo file con nome Unicode fra Finder ed Explorer, verificando contenuto e destinazione. Coprire entrambi i percorsi UI senza costruire una matrice estesa; aggiungere solo un caso mirato di annullamento/errore per la logica che può perdere dati. Percorsi condivisi e file locali non condivisi devono avere esito dichiarato; registrare separatamente i limiti ancora aperti. Nessuna di queste prove è stata eseguita per aggiornare la lista.

## TODO-004 — Tutti i tempi della pipeline grafica

**Stato: DA FARE; copertura parziale già nel codice.** Occorrono due rapporti distinti: **desktop Windows → finestra desktop Mac** e **singola app Windows → propria finestra Mac**. Obiettivo: attribuire latenza e lavoro ai componenti, individuare il collo di bottiglia e ottimizzare solo dopo una misura utile.

Ricognizione dei sorgenti, non nuova verifica runtime:

- `GuestBridge.swift` registra alcuni tempi di readback/trasporto/dispatch e ultimo RTT; non tutte le chiavi valgono per ogni percorso. I tempi readback/encode di un vecchio percorso pixel non descrivono automaticamente il percorso GPU corrente.
- `guest/src/windows/gpu.rs` pubblica selezione QPC, invio e attesa query GPU. L'attesa usa polling e sleep: non misura soltanto il tempo di esecuzione GPU.
- `NativeWindowFrames.swift` misura fino al completamento della copia Metal con un orologio CPU: include preparazione, coda e callback; non è il solo tempo GPU.
- `WindowRenderer.swift` ha già una callback di presentazione per lo stato della finestra, ma non registra `presentedTime` in una timeline completa. Il desktop importa una superficie condivisa e il presenter la copia in una texture locale prima dell'ACK: non è zero-copy. Contatori di frame/risorse/pending non sostituiscono i tempi.

**Prossimo risultato:** una mappa con una riga per ogni stadio, ingresso/uscita, ID frame correlato, orologio, strumento, copertura e incertezza. Ogni tratto deve risultare misurato, stimato con limite dichiarato oppure non osservabile con motivo. Individuare almeno:

| Tratto da coprire | Desktop | Singola app |
| --- | --- | --- |
| Input e produzione del contenuto | Invio input, ricezione guest, elaborazione dell'app | Stessi confini, includendo trasformazione coordinate/focus. |
| Rendering Windows | Lavoro CPU, invio D3D, driver/GPU virtuale, composizione DWM e present | Stesso lavoro dell'app e composizione pertinente. |
| Acquisizione/pubblicazione | Scanout e pubblicazione del desktop | Selezione frame WGC, età del frame, eventuale crop/copia, attesa e metadati. |
| Runtime grafico | Guest/virtqueue, QEMU, renderer/server, traduzione, invio e completamento backend Metal | Correlare il lavoro della superficie esportata, senza contare due volte il rendering già attribuito. |
| Arrivo host | Notifica, attesa superficie/fence, import, code verso UI | Associazione risorsa/metadati, attesa, import e copia locale. |
| Presentazione Mac | Acquisizione drawable, copia/disegno, accodamento GPU, completamento e presentazione | Stessi confini nella finestra individuale. |
| Riuso e fluidità | ACK, backpressure, frame scartati/ripetuti, risorse ancora vive | Idem, per finestra/generazione/sequence. |

La tabella è una lista di punti d'osservazione: alcune operazioni si sovrappongono e il rendering Windows attraversa già il runtime host. Non sommare indiscriminatamente righe e medie. Correlare frame, finestra, superficie, generazione e presentazione; includere frame persi ed errori, non solo i riusciti.

**Meccanismi concreti individuati:** [ETW/GPUView](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-gpuview) per eventi Windows realmente emessi da DWM/DxgKrnl/driver; trace QEMU e timestamp nei confini del renderer; [Metal System Trace/Instruments](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app) e signpost host; [GPUStartTime/GPUEndTime](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime) per esecuzione dei command buffer dopo completamento; [presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime) per presentazione riportata da Metal, considerando zero/frame scartati. Disponibilità degli strumenti e qualità degli eventi nel driver virtuale devono ancora essere accertate; niente garanzia di osservare ogni interno del driver.

QPC Windows e orologio monotono Mac non sono direttamente sottraibili: [QPC misura intervalli nello stesso sistema/VM](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps). Servono correlazione e calibrazione offset/deriva con incertezza esplicita, mantenendo le durate locali quando non c'è sincronizzazione affidabile. Il callback CPU non coincide necessariamente con l'istante GPU o con la visualizzazione.

Il difetto Wait/Signal di TODO-016 condiziona l'interpretazione delle misure guest: una risposta query di completamento non dimostra da sola che le dipendenze fra produttore e consumer siano state rispettate. Non classificare come più veloce un percorso che legge prima del momento consentito.

**Fatto quando:** per entrambi i percorsi una breve azione reale produce una timeline correlata, durate e code per stadio, distribuzione dei tempi e frame persi; i tratti mancanti sono evidenziati e il collo di bottiglia è sostenuto dai dati. Riportare numero di campioni e overhead della strumentazione, evitando percentili estremi senza campioni sufficienti. Una misura software di presentazione non è una misura fisica fino alla luce emessa dal display: quest'ultima richiede strumentazione esterna. Se un tratto non è osservabile, avvisare senza sostituirlo con zero o dichiarare copertura totale.

## TODO-005 — Disco e I/O

**Stato: DA FARE. Ha senso analizzarlo, ma non è ancora dimostrato che sia un collo di bottiglia.** Il percorso configurato è filesystem Windows → NVMe virtuale → QEMU/block layer → qcow2 → file host/APFS → storage Mac; cache e flush esistono in più livelli. Il dispositivo NVMe presentato al guest non è passthrough del disco fisico. Le future cartelle condivise di TODO-003 avranno un percorso distinto dal disco Windows.

**Meccanismi:** [QMP query-blockstats](https://github.com/qemu/qemu/blob/master/qapi/block-core.json) espone operazioni, byte e tempi cumulativi anche sui nodi sottostanti; differenze tra campioni danno tassi e tempi medi, non automaticamente la latenza di ogni richiesta. Per dettagli esistono i [trace-event QEMU](https://www.qemu.org/docs/master/devel/tracing.html), da scegliere nel build effettivo. Sul Mac, [Instruments File Activity](https://developer.apple.com/documentation/xcode/reducing-disk-writes) distingue attività logica e I/O fisico con durate. Nel guest, ETW File/Disk I/O e, solo per una domanda concreta, [DiskSpd ARM64](https://github.com/microsoft/diskspd) su un piccolo file temporaneo. Esistenza documentata degli strumenti, disponibilità locale e copertura non ancora provate.

**Prossimo passo:** scegliere un'operazione utile, per esempio avvio app o apertura/salvataggio documento, e associare attesa guest, code QEMU, attività qcow2/APFS e flush. Distinguere cache calda/fredda e paginazione dovuta alla RAM da vero costo storage. Limitare durata, spazio e scritture; mai fare benchmark direttamente sull'immagine VM dal lato host mentre è in uso.

**Fatto quando:** un rapporto circoscritto dice se esiste un limite rilevante, dove e con quale evidenza; solo allora una modifica motivata con confronto della stessa operazione. Se non emerge un costo rilevante, chiudere l'analisi senza inventare un'ottimizzazione. Non disabilitare flush/durabilità per ottenere numeri migliori. Se mancano strumenti/eventi utili, segnare il tratto bloccato e avvisare.

## TODO-006 — CPU, idle e impatto sul Mac

**Stato: DA FARE.** Non dare per scontato che la CPU sia irrilevante: la VM sempre accesa deve costare poco anche senza finestre aperte. Separare vCPU Windows, QEMU/HVF, renderer/server, servizio guest, polling e UI Mac; distinguere lavoro CPU da tempo trascorso in attesa.

**Meccanismi:** Time Profiler e stato dei thread in Instruments sul lato host; tempi CPU di processo/thread Windows e trace ETW scheduler/context switch sul lato guest. Il comando guest `gpu::clock` già espone QPC/frequenza e CPU del worker: non rappresenta tutta la VM. Il campionamento CPU WPR non è garantito nella nostra IoT virtualizzata: la [FAQ Microsoft ARM](https://learn.microsoft.com/en-us/windows/arm/faq) documenta persino vincoli di canale per VM Hyper-V ARM. Non trasferire automaticamente quella disponibilità a HVF, né cambiare LTSC in Insider per profilare. Se manca il campionamento, usare tempi processo/thread e confini espliciti per le sole domande che possono risolvere, dichiarando la minore attribuzione.

**Prossimo passo:** verificare prima quali misure sono ottenibili, poi un confronto breve fra background senza finestre, desktop aperto e una singola app con la stessa azione. Contare risvegli/polling e carico host complessivo oltre all'utilizzo percentuale. Energia/consumo batteria richiedono una misura propria, non si deducono dalla sola percentuale CPU. Non sommare guest CPU e thread vCPU host come se fossero lavoro indipendente.

**Fatto quando:** costo idle e costo dell'azione attribuiti almeno ai componenti osservabili; eventuale intervento riduce lavoro/risvegli senza rendere la VM meno reattiva o sospenderla. Se manca un meccanismo utile per una domanda, registrare il limite e avvisare, senza lanciare carichi sintetici alla cieca.

## TODO-007 — GPU e traduzione grafica

**Stato: DA FARE.** Distinguere CPU di driver/renderer/traduzione da esecuzione GPU Metal, copie, sincronizzazione e attesa della presentazione; l'utilizzo della GPU virtuale non descrive da solo il lavoro della GPU Apple.

**Meccanismi:** timeline di TODO-004, Metal System Trace e tempi command buffer. I contatori dettagliati sono condizionati da [counterSets/supportsCounterSampling](https://developer.apple.com/documentation/metal/mtldevice/countersets) del dispositivo e dai confini supportati; non promettere cache/banda/occupancy prima di averne accertato l'esposizione. Analogamente, query timestamp D3D o eventi ETW del guest non diventano automaticamente tempi fisici Apple attendibili.

**Prossimo passo:** mappa delle misure disponibili sul backend effettivo, quindi una sola scena/azione reale sufficiente a separare lavoro CPU, copie e GPU. Collegare i dati a risoluzione, scala e numero di superfici. Evitare benchmark estesi o modifiche del driver per il solo desiderio di avere più contatori.

**Fatto quando:** costo grafico attribuito con limiti espliciti e, se il collo di bottiglia è correggibile, confronto concreto prima/dopo. Se non sono disponibili contatori o timestamp utili, avvisare e limitare l'analisi alle parti osservabili; nessuna stima presentata come misura hardware.

## TODO-016 — Sincronizzazione GPU: Wait/Signal non rispettato

**Stato: difetto APERTO; soluzione protetta qualificata BLOCCATA nella combinazione attuale.** È [GFX-007](KNOWN_ISSUES.md#gfx-007--fence-waitsignal-e-pubblicazione-gpu), non un esperimento concluso. Le candidate kernel/UMD e il gate host sono stati ritirati, ma il difetto che cercavano di correggere resta da risolvere.

**Evidenza già acquisita:** con il driver ARM64 Microsoft-signed v0.4, due device sullo stesso adattatore e una query EVENT nuova, un Wait sul valore1 lascia eseguire Clear/Copy e leggere i nuovi pixel mentre la fence è ancora0. Quindi non è soltanto una query che risponde prematuramente. Prova del 23 ottobre sul nostro host Neptune/DXMT modificato: non una riproduzione su UTM intatto né una nuova prova sulla IoT oggi principale. [Diario della riproduzione](VERIFICATION.md#23-ottobre--wait-d3d11-non-trattiene-query-e-scrittura-dei-pixel).

**Segnalazione esterna:** [nostro commento nell'issue8 di osy/kvm-guest-drivers-windows](https://github.com/osy/kvm-guest-drivers-windows/issues/8#issuecomment-6374085762), pubblicato il23 ottobre. L'issue era già stata aperta da un altro utente per testo XAML mancante con v0.3; il nostro contributo documenta il distinto errore Wait/Signal su v0.4. Al controllo documentale del25 ottobre l'issue è aperta e l'ultimo dei due commenti è ancora il nostro, senza risposta successiva. Non è una conferma del maintainer di causa o correzione.

**Prossimo passo / sblocco:** valutare una correzione upstream o una modifica compatibile del percorso scheduler WDDM → esecuzione host, distinguendo ordine di invio, autorizzazione all'esecuzione e completamento. Per distribuire serve una coppia driver/runtime accettata con Secure Boot/CI e modalità test disattivata; nessuna soluzione così qualificata è documentata. Le prove circoscritte delle candidate non bastano: una provocava arresti DWM. La verifica sul pacchetto main sarà necessaria quando si riprenderà il lavoro, non in questo aggiornamento documentale; non ripetere ora il probe o riattivare candidate ritirate.

**Fatto quando:** il lavoro successivo a Wait resta fermo fino al Signal nel caso minimo pertinente, poi il percorso reale tra produttore/consumer conserva immagini complete e aggiornate, senza regressioni DWM e con protezioni attive. Non basta che GetData restituisca successo. Il legame con ogni caso di testo mancante, WGC stale o flicker resta da dimostrare separatamente: non attribuirli tutti a questa causa per deduzione.

## Altri problemi da non perdere

Queste voci derivano dal registro corrente; non sono nuove promesse di funzionalità.

### TODO-008 — Contenuto grafico e durata delle risorse

**Stato: DA FARE.** [GFX-001/003](KNOWN_ISSUES.md#gfx-001--flicker-e-cifre-mancanti-nelle-catture-wgc): etichette/cifre mancanti, catture ferme e recupero incompleto. [GFX-004](KNOWN_ISSUES.md#gfx-004--risorse-grafiche-indisponibili-e-recupero-incompleto): saturazione storica live256 e presenter nero. Sono problemi distinti da geometria/DPI e non risolti dalla nuova RAM o dalla pulizia.

Prossimo passo: quando si affronta il singolo difetto, conservare un caso reale e correlare produzione/cattura, ownership, fence e rilascio. **Fatto quando:** lo stesso caso mostra contenuto completo e aggiornato e recupera le risorse senza riavviare tutta la VM; una breve sessione senza guasti non dimostra durata indefinita. Il limite screenshot GFX-008 si approfondisce solo se serve una cattura affidabile o compare un'anomalia realmente visibile.

### TODO-009 — Arresto, riavvio e recupero

**Stato: DA FARE.** [SYS-001](KNOWN_ISSUES.md#sys-001--arresto-hvf-durante-riavvio-o-arresto): assertion HVF durante shutdown/restart, anche con driver ufficiale. Un successivo avvio e un controllo disco riusciti non isolano la causa.

Prossimo passo: al guasto pertinente preservare istruzione/MMIO e contesto, poi correggere il percorso identificato. **Fatto quando:** il passaggio prima difettoso riesce con la correzione causale e l'app comunica perdita/recupero della sessione in modo utilizzabile. Preservare documento e identità della finestra in riconnessione; evitare duplicazioni o input rimasto premuto.

### TODO-011 — Launcher e finestre già aperte sulla main

**Stato: DA FARE per la qualifica ordinaria.** Catalogo, icone persistenti, preferiti/recenti sono implementati; [APP-002](KNOWN_ISSUES.md#app-002--esplora-file-assente-e-finestre-riusate-non-riconosciute), drag e attesa resize hanno prove precedenti nel clone. La promozione non equivale a nuova verifica delle singole app nella IoT principale.

Prossimo passo: nel futuro lavoro sulle finestre, breve apertura/ripresa di Explorer e di un'app che riusa processi, con lo stesso documento già aperto. **Fatto quando:** la main associa le finestre corrette, non ingloba il desktop/taskbar, non duplica app o documento, gestisce primo frame/resize/focus. Qualifica del launcher e completezza dei pixel restano criteri distinti.

## Risultati conservati e lavoro rinviato

### TODO-012 — RAM dinamica protetta

**Stato: FATTO nel perimetro SYS-003.** Balloon e hotplug/unplug reali nella IoT pulita, stessi runtime poi promossi nella main. Nel ciclo Native3D protetto 4→2→4 GiB senza reboot: 1034 MiB hotadded rimossi fisicamente, altri 1014 MiB pinned compensati dal balloon; footprint Mac ridotto di circa 477,5 MiB, probe 128 MiB integro per 48 letture e nuova allocazione 256 MiB verificata dopo il ritorno. Secure Boot/CI attivi, TESTSIGNING falso. [Prove e limiti](VERIFICATION.md#25-ottobre--iot-pulita-balloon-hotplug-e-controllo-automatico), [promozione](VERIFICATION.md#25-ottobre--pulizia-definitiva-e-promozione-iot-a-base-principale).

Non è una promessa di unplug completo o footprint minimo fisso. La promozione ha confermato avvio protetto/controller con gli stessi binari, senza ripetere il ciclo esteso. Preservare questo risultato; modifiche al backing RAM, in particolare TODO-003, richiedono una verifica pertinente successiva. CPU idle e risvegli restano TODO-006, i difetti grafici restano aperti.

### TODO-013 — Una base principale

**Stato: FATTO.** `/Applications/Perpendicular.app` 0.2.0 e IoT principale come default; vecchi launcher/dischi eliminati su autorizzazione, backup completo offline e build qualificata originale conservati. [Evidenze](VERIFICATION.md#25-ottobre--pulizia-definitiva-e-promozione-iot-a-base-principale). Non ricreare i vecchi dischi o riprendere una pulizia delle Research incerte per completismo. Questo completamento non chiude resize, WGC o N+1.

### TODO-014 — Creality/OpenGL

**Stato: RINVIATO su richiesta dell'utente (APP-001).** Nessuna qualifica completa del rendering. Riprendere su nuova priorità esplicita o necessità concreta del percorso attivo, senza inserirlo automaticamente nelle prove delle prestazioni.

### TODO-015 — Esperimenti già valutati

**IVSHMEM: valutazione FATTA, decisione di non adozione (TRN-001).** Frame reali verificati, vantaggio generale su TCP+LZ4 non dimostrato. Non è un componente mancante da implementare automaticamente. **Candidate DWM/driver auto-firmate: RITIRATE** (GFX-002/005 e tentativi storici di GFX-007); non appartengono alla soluzione protetta attuale. Il difetto di sincronizzazione GPU GFX-007 resta aperto in TODO-016: il ritiro dei tentativi non ne costituisce la soluzione. Storia e motivi in [RETIRED_EXPERIMENTS.md](RETIRED_EXPERIMENTS.md) e nel diario.

## Ultimo aggiornamento documentale

25 ottobre: registrate le nuove richieste e i meccanismi candidati da fonti primarie, letti i punti di misura nei sorgenti e collegati i difetti esistenti. Nessuna nuova misura o qualifica runtime. [Voce del diario](VERIFICATION.md#25-ottobre--todo-obbligatoria-e-ricognizione-documentale).

Successiva revisione richiesta dall'utente: rimossa la voce su spazio/aggiornamenti/ripristino; conservati gli altri ID. Aggiunta TODO-016 per il difetto sync GPU e corretto GFX-007, che era stato confuso con i tentativi ritirati. [Revisione documentale](VERIFICATION.md#25-ottobre--revisione-todo-e-difetto-di-sincronizzazione-gpu).

Aggiunte TODO-017/018 per comandi Mac e appunti testo/file bidirezionali, distinguendo codice e verifica storica dal lavoro ancora necessario sulla main. [Revisione documentale](VERIFICATION.md#25-ottobre--requisiti-comandi-mac-e-appunti-trasversali).
