# Piano essenziale delle applicazioni Windows su Mac

## Obiettivo

Creare un'applicazione Mac che mostri il catalogo delle applicazioni Windows di una VM locale e consenta di aprirle e usarle in finestre individuali sul Mac. Windows continua a eseguire e disegnare le applicazioni; al Mac devono arrivare i contenuti delle finestre interessate e delle relative finestre secondarie.

Il desktop Windows completo deve restare accessibile per installazione, manutenzione e recupero.

Il percorso iniziale senza 3D è stato implementato con verifiche puntuali riportate in [VERIFICATION.md](VERIFICATION.md). La fase attiva è descritta sotto: geometria condivisa, monitor virtuali, presentazione Metal e integrazione del percorso 3D. Le decisioni di partenza rimangono il contesto del restart, senza impedire questa evoluzione autorizzata dall'utente.

## Decisioni di partenza

- Creare una VM pulita e ricostruire le integrazioni guest necessarie.
- Partire senza accelerazione 3D del guest.
- Dare priorità ad avvio, connessione, input e riconnessione affidabili.
- Costruire prima una singola app utilizzabile, poi il catalogo completo e le integrazioni aggiuntive.
- Permettere aggiornamenti dei componenti senza legare tutta l'app a un unico protocollo o driver.

## Scelte tecniche da verificare

Motore della VM, edizione di Windows, linguaggi, librerie, trasporto e protocollo delle finestre restano scelte da motivare con prove sul sistema effettivo.

RemoteApp, RAIL e RDPEGFX sono candidati da valutare, non requisiti del prodotto. Verificare entrambe le estremità: ciò che il guest può offrire e ciò che il client Mac può gestire. Il supporto a un desktop remoto non dimostra automaticamente la disponibilità delle singole finestre.

Scegliere un solo percorso iniziale dopo una prova completa. Documentare motivo della scelta, limiti accettati e condizione concreta che ne giustificherebbe la sostituzione.

## Responsabilità da separare

| Parte | Responsabilità |
| --- | --- |
| Controllo della VM | Avvio, arresto, stato e recupero anche quando le integrazioni guest non rispondono |
| Collegamento guest | Identità, capacità disponibili, richieste, errori e riconnessione |
| Applicazioni e sessione | Catalogo, avvio, utente e sessione corretti, finestre e dialoghi |
| Immagini e input | Aggiornamenti per finestra, geometria, focus, mouse e tastiera |
| Interfaccia Mac | Ricerca, finestre native e rappresentazione degli stati reali |
| Integrazioni aggiuntive | Documenti, appunti e file secondo necessità |

Definire soltanto i confini utili all'implementazione presente. La UI deve poter usare le operazioni del prodotto senza dipendere dai dettagli del protocollo sottostante.

## Prima prova completa

1. Avviare la nuova VM e raggiungere un desktop utilizzabile.
2. Aprire una normale applicazione Windows e mostrarne la finestra sul Mac.
3. Usarla con mouse e tastiera, ridimensionarla e gestire un dialogo secondario.
4. Interrompere e ripristinare il collegamento, ritrovando lo stato corretto senza duplicare le app.
5. Recuperare dall'uscita di un componente e verificare nuovamente avvio, arresto e accesso al desktop.
6. Provare il pacchetto finale e registrare risultati ed errori; ripetere soltanto i passaggi interessati dalle correzioni.

L'accettazione di un comando, la disponibilità della finestra e la visualizzazione del contenuto sono stati distinti. Una disconnessione non deve provocare perdita di dati, app duplicate o tasti bloccati.

## Evoluzione

Trasporto, codifica delle immagini, gestione delle finestre, condivisione dei file e accelerazione 3D devono poter evolvere attraverso confini espliciti e versioni compatibili. Per ogni aggiornamento stabilire cosa cambia, cosa resta stabile, come verificarlo e come tornare alla versione precedente.

L'accelerazione 3D viene affrontata dopo la base affidabile. Un cambio di driver o modello di sessione può richiedere riavvio e nuove prove: la modularità riduce il lavoro da rifare, non lo elimina.

## Obiettivo attivo — geometria condivisa e percorso grafico

Portare Perpendicular a un'app Mac utilizzabile in cui le applicazioni Windows di una sola VM locale vivono in finestre individuali, con posizione, dimensioni e scala coerenti fra i due sistemi. Il risultato deve funzionare nel pacchetto finale aperto normalmente, non soltanto in un prototipo o in un test isolato.

L'esperienza attesa è concreta: aprire Perpendicular, avviare o ritrovare la VM, scegliere un'app Windows e usarla sul Mac. Trascinamento, ridimensionamento, menu e input devono continuare a funzionare senza interventi manuali nel terminale, riavvii del guest agent o riparazioni della sessione. Una disconnessione temporanea deve recuperare le finestre già aperte e i loro documenti.

Il risultato prioritario è una prima app realmente utilizzabile lungo tutto questo percorso. Non occorre completare ogni possibile integrazione, certificare tutte le app Windows o costruire preventivamente un framework generale. Ogni componente aggiunto deve servire una parte concreta del risultato.

### Monitor e scala

Rappresentare in Windows i monitor Mac necessari, con disposizione, risoluzione e DPI coerenti. Partire dallo schermo reale disponibile e mantenere il modello adatto a più monitor, distinguendo ciò che è implementato dalle configurazioni effettivamente provate. Superare il limite provvisorio di 800×600.

La configurazione dello schermo segue i monitor: il resize di una singola app modifica la sua finestra, senza riconfigurare continuamente l'intero desktop o disturbare le altre app aperte. Gestire esplicitamente punti Mac, pixel e DPI per conservare dimensioni percepite e nitidezza, anche nel passaggio fra schermi con scale diverse.

La corrispondenza 1:1 riguarda la geometria percepita e il comportamento del gesto: una distanza trascinata sul Mac deve produrre lo spostamento corrispondente in Windows. Su Retina non significa confondere un punto Mac con un pixel Windows. Rendere esplicita la trasformazione delle coordinate, compresi origine dei monitor e scala, e usare lo stesso modello per immagini, input, finestre e popup.

Non vincolare l'aumento della risoluzione al completamento dell'accelerazione 3D: monitor virtuale e accelerazione hanno responsabilità distinte. Scegliere il percorso operativo in base alle capacità effettive del driver e del runtime disponibili.

### Drag, resize e comportamento delle finestre

Far corrispondere posizione e dimensioni di ogni finestra Mac alla relativa finestra Windows. Il Mac risponde immediatamente al gesto; Windows segue con aggiornamenti controllati, senza salti, doppio movimento o cicli di feedback. Aggiornare il contenuto durante il resize e rispettare i minimi e le dimensioni realmente accettate dall'app.

Durante il gesto mantenere utilizzabile il contenitore Mac; al termine riconciliare la geometria con quella accettata da Windows. Una risposta in ritardo o appartenente a una connessione precedente non deve annullare il movimento più recente. Se un'operazione fallisce, terminare il gesto, rilasciare i pulsanti e tornare a uno stato utilizzabile, mostrando l'eventuale errore.

Conservare i controlli Windows delle finestre principali. Menu, tooltip e popup rimangono associati al proprietario; i veri dialoghi conservano i controlli Mac previsti. Mouse e tastiera devono restare utilizzabili dopo drag, resize, cambio focus e riconnessione. Il desktop completo rimane raggiungibile per manutenzione e recupero.

Evolvere la base attuale senza revert indiscriminati: conservare recupero dell'input, classificazione delle superfici e controlli utili. Sostituire i limiti provvisori di geometria e il resize applicato soltanto al rilascio quando il nuovo percorso funziona.

### Grafica e riuso del vecchio progetto

Tenere separati monitor virtuale, accelerazione 3D Windows, cattura/trasporto delle singole finestre e presentazione Metal, con confini semplici e sostituibili.

Consultare il vecchio progetto per rispondere a domande precise e riusare soltanto i componenti pertinenti e compatibili del percorso driver/3D. Conservare versioni coerenti e verificare rendering Windows reale; una prova del solo desktop o di WebGL non dimostra compatibilità generale. Non importare vecchi agenti, configurazioni di sharing o l'intera architettura.

Presentare le finestre tramite Metal e ridurre copie e attese dove il percorso concreto lo consente. Un presenter Metal da solo non prova che il guest sia accelerato; un trasferimento che copia i pixel non va descritto come zero-copy. Evitare il disegno parallelo della console QEMU durante l'uso ordinario, quando il backend lo permette, mantenendo il recupero del desktop.

La prova del percorso grafico deve distinguere tre risultati: Windows usa realmente il dispositivo grafico previsto; il contenuto della singola finestra arriva al Mac; Metal lo presenta senza perdere input, popup o recupero. Una console accelerata a schermo intero, da sola, non completa l'obiettivo delle applicazioni individuali.

Usare subito i linguaggi target: Swift/AppKit/Metal sul Mac, Rust per l'integrazione guest esistente e il linguaggio richiesto dal driver/SDK dove necessario. Motivare nuove dipendenze con un bisogno concreto.

### Ordine di lavoro e protezione della base

Direzione aggiornata dall’utente: abbandonare RDP, rimuovere la password temporanea e le relative impostazioni e proseguire con il driver/acceleratore locale. Le app aperte nella copia di sviluppo possono essere chiuse durante queste prove; la VM originale e i suoi dati restano intatti. L’autorizzazione riguarda lo stato delle app nella copia, non la cancellazione indiscriminata dei dati.

Aggiornamento del 21 ottobre 2026, chiarito esplicitamente dall’utente: partire dalla VM esistente e rimuovere dalla sola copia di sviluppo gli agenti vecchi e lo sharing file precedente. Inventariare e rimuovere le integrazioni riconosciute, ripristinare le cartelle locali Windows senza cancellare o spostare i documenti e conservare una ricevuta delle modifiche. L’installer ordinario del bridge rimane separato da questa pulizia una tantum. Usare una copia recuperabile e lasciare intatta la VM originale. Se questa VM risulta concretamente inadatta, l’utente autorizza una prova separata con Windows 11 IoT Enterprise LTSC 2024 Evaluation ARM64; non sovrascrivere il sistema esistente e non attribuire al cambio di edizione una soluzione grafica non dimostrata.

Successiva indicazione esplicita dello stesso giorno: interrompere la ricerca e pulizia dei residui Parallels e procedere con display, grafica e finestre. I Tools non sono un criterio di blocco. Se il sistema impedisce concretamente di avanzare, preparare una nuova installazione separata, preferibilmente IoT; non proseguire inventari o disinstallazioni per completismo.

Indirizzo ribadito dall'utente: il vecchio percorso 2D non è una base approvata o affidabile. Una riuscita storica non supera i problemi osservati di avvio, artefatti e risoluzione dinamica. I suoi runtime recuperati restano esperimenti da confronto; non promuoverli al percorso ordinario. Dare priorità ai vincoli ricavati dall'analisi di Parallels: monitor/topologia/DPI confermati prima dell'integrazione delle finestre, controllo di geometria/input/attivazione con identità e risposte, immagini e accelerazione separabili. Le osservazioni su Parallels sono statiche, non una ricostruzione verificata del protocollo o del funzionamento interno. Ogni backend scelto deve dimostrare questi comportamenti nell'app attuale.

1. Individuare monitor reali, capacità del display guest e componenti grafici riusabili; predisporre un ritorno al percorso funzionante prima di sostituire driver o runtime.
2. Rendere operativo lo schermo virtuale adeguato e sincronizzare drag, resize e scala fra Mac e Windows, completando una prima app utilizzabile.
3. Integrare la presentazione Metal e il percorso 3D compatibile, verificando separatamente rendering guest e trasporto delle singole finestre. L'ordine di questi due componenti può seguire le dipendenze effettive emerse dal primo passaggio.
4. Ricompilare, aprire e verificare brevemente il pacchetto finale; aggiornare le evidenze e pubblicare le modifiche su GitHub.

Procedere per piccoli risultati completi, mantenendo l'app compilabile e recuperabile. Preservare app, documenti e stato della VM corrente e lasciare intatta la VM originale. Non indebolire le protezioni Windows. Registrare capacità verificate e limiti reali, con commit coerenti e push periodici. Compatibilità universale, nuove integrazioni e rifacimenti estranei non fanno parte di questo obiettivo.

Per ogni passaggio scegliere un solo risultato osservabile e la verifica minima che lo conferma. Quando funziona, integrarlo e passare al successivo. Se un componente assorbe tentativi ripetuti senza produrre un miglioramento utilizzabile, annotare il problema, mantenere o ripristinare il percorso funzionante e scegliere un passo più piccolo o un'alternativa concreta. Evitare di restare bloccati a perfezionare un backend o la sua infrastruttura di test.

### Pochi test mirati

Scegliere il minimo necessario per rispondere a un dubbio concreto: normalmente una breve prova visibile end-to-end e, soltanto se utile, pochi controlli automatici della logica critica. Privilegiare il percorso reale: aprire un'app, trascinarla, ridimensionarla, usare un popup o dialogo, continuare a interagire e recuperarla dopo una riconnessione.

Non costruire centinaia di test, grandi harness, matrici di benchmark o test che replicano l'implementazione. Dopo una verifica riuscita proseguire; ripeterla solo per una modifica pertinente o un nuovo problema. Se un tentativo fallisce, correggere la causa e riprovare il percorso interessato, senza aggiungere infrastruttura sproporzionata o incastrarsi a perfezionare un sottocomponente.

Per questa fase bastano poche prove rappresentative, distribuite nei passaggi che le richiedono:

- Aprire un'app dal pacchetto finale, trascinarla e ridimensionarla oltre il vecchio limite; verificare che il contenuto segua e che mouse e tastiera funzionino ancora.
- Aprire un menu o popup e un vero dialogo, verificando associazione al proprietario, posizione e controlli previsti. Riutilizzare le evidenze già valide se il percorso non è cambiato.
- Ripristinare una connessione interrotta, ritrovare la stessa app senza duplicarla e raggiungere il desktop di recupero.
- Sul percorso 3D, osservare un rendering reale con il dispositivo previsto e la presentazione Mac; registrare chiaramente se la singola finestra usa ancora copie CPU.

Non eseguire tutte queste prove dopo ogni modifica. Build, controlli di firma e verifiche dei payload necessari al rilascio completano la verifica; non giustificano una nuova infrastruttura di test. Il successo si misura nel comportamento dell'app e nei problemi risolti, non nel numero di test aggiunti.

### Criterio di completamento

Una normale app Windows si apre nella propria finestra Mac; drag e resize rimangono coerenti oltre il vecchio limite grazie allo schermo virtuale appropriato; popup/dialoghi e input funzionano; una riconnessione recupera l'app e il desktop resta accessibile. Il percorso 3D/Metal integrato ha una prova reale e limiti espliciti. Consegnare l'app ricompilata e aperta, la documentazione essenziale aggiornata e le modifiche pubblicate su GitHub.

Nel resoconto finale indicare cosa è utilizzabile, quali brevi prove lo confermano e quali limiti restano. Una build riuscita, un comando accettato o una superficie visualizzata una volta non sostituiscono il risultato completo. Finché manca una parte essenziale, l'obiettivo rimane aperto.

## Obiettivo successivo — fluidità, compatibilità e launcher

Richiesta esplicita del 21 ottobre 2026, dopo il primo percorso Win32 completo:

1. Migliorare click, testo, scroll e fluidità delle immagini. Consultare selettivamente il vecchio progetto, misurare i colli di bottiglia concreti e ridurre copie/attese GPU dove il percorso reale lo consente. Distinguere la rimozione di un upload Mac dal vero zero-copy Windows–Mac.
2. Ampliare le app supportate a WinUI e Creality Print, comprese splash/loading window e transizione alla finestra principale. Verificare separatamente scoperta/identità delle finestre, rendering guest e cattura. Una riuscita Win32 non certifica WinUI o OpenGL.
3. Rifare il launcher Swift con interfaccia moderna e usabile, ricerca immediata, stati di apertura effettivi e icone Windows reali per i software.

Conservare desktop di recupero, VM originale e documenti. Completare incrementi piccoli nell'app reale con commit/push, senza riprendere pulizie Parallels o cambiare driver per tentativi. Le scorciatoie Mac rimangono fuori da questa fase.

Aggiornamento successivo dell’utente: saltare per ora il problema specifico di Creality. Il lavoro attivo prosegue su launcher, fluidità e compatibilità generale; Creality resta rinviato senza richiedere di risolverne adesso OpenGL, configurazione o avvio.

## Lavoro futuro — scorciatoie Mac

Richiesta dell’utente del 21 ottobre 2026, da non implementare nella fase attuale: introdurre le scorciatoie in stile Mac nelle applicazioni Windows. Consultare l’implementazione della vecchia app Perpendicular soltanto per recuperare il comportamento pertinente, distinguendo scorciatoie, testo composto e appunti. Questa voce non amplia il lavoro attivo su monitor, grafica e geometria.


## Obiettivo corrente — stabilità e fluidità 3D, 22 ottobre 2026

Su nuova richiesta dell’utente riprendere il percorso grafico locale, dando priorità a meno crash, blocchi e scatti e alla riduzione delle copie effettive. Usare i nuovi guest tool per eseguire comandi nella VM direttamente dal Mac. Non richiedere una console PowerShell interattiva per la normale manutenzione.

Procedere con piccoli risultati completi:

1. Verificare il runtime realmente avviato e integrare nella sua build compatibile il rifiuto dei contesti in eccesso prima di creare processi renderer. Conservare un runtime precedente e un checkpoint prima del cambio; non aumentare indiscriminatamente i limiti.
2. Stabilizzare il ciclo di vita della cattura: stato e fine del thread riferiti al singolo run, isolamento delle vecchie connessioni e recupero limitato soltanto quando il guasto è identificato. Controllo e input devono rimanere utilizzabili.
3. Ridurre allocazioni, copie e attese nel percorso reale misurato. Distinguere accelerazione Windows, cattura/trasporto della finestra e presentazione Metal: chiamare zero-copy soltanto i tratti senza copia, senza attribuirlo all’intero percorso BGRA su TCP.
4. Fare pochi controlli mirati: compilazione e una breve prova reale di contenuto, movimento/resize e riconnessione interessati dalla modifica. Niente grandi harness, centinaia di test o benchmark estesi. Se un intervento non dà progresso utilizzabile, registrare il limite e passare a un passo più piccolo.
5. Pubblicare incrementi coerenti su GitHub, aggiornare le evidenze e lasciare l’app ricompilata e aperta. Preservare documenti e VM originale; Creality specifico e scorciatoie Mac restano rinviati.

Il primo ciclo deve consegnare almeno un miglioramento concreto integrato e verificato, con limiti e prossimo intervento espliciti. Una singola riuscita non certifica l’affidabilità generale e un retry non dimostra risolta la causa.

Primo incremento del22 ottobre: runtime del Mac aggiornabile correttamente nel pacchetto, ammissione anticipata dei contesti integrata nella base effettiva, stato cattura isolato alla riconnessione e attesa prima del readback sotto backpressure. Build e controllo C mirato riusciti; finestra Win32 aggiornata fino all’ultimo stato e recuperata dopo riconnessione con lo stesso identificatore. Evidenze e tentativi falliti in VERIFICATION.md. L’obiettivo generale rimane aperto: guasti WinUI, eventuali stalli GET_BLOB e copie WARP/TCP non sono risolti da questo incremento.

Prossimo passo: partire da questo runtime verificato e dallo stato per-run per separare blocco della cattura, risorse del renderer e trasporto; valutare la riduzione del volume BGRA o un percorso di superficie condivisa per finestra soltanto con una prova completa. Non ripetere l’autoaggiornamento del servizio come figlio di`execute`, neppure con il semplice RunAs: l’arresto del worker può interromperlo. Usare un installer realmente indipendente; i normali comandi possono essere eseguiti direttamente dal Mac.

## Punto di ripresa precedente — stop richiesto il 22 ottobre 2026

Prova fermata su richiesta dell’utente, modifiche annotate e pubblicate. Il frontend diagnostico è chiuso; la sola VM di sviluppo rimane accesa. VM originale e documenti intatti. Build finale Mac9418153157d9, guest diagnostico e4bc516cf7c7; dettagli e limiti in VERIFICATION.md. Non considerare risolto il blocco intermittente della cattura dopo aggiornamento/riconnessione del bridge.

Alla ripresa, nell’ordine:

1. Riprodurre quel singolo guasto confrontando sequenza frame, capturePhase/captureStopped e desktop reale. L’ultimo aggiornamento del servizio ha ripristinato i frame, quindi non è una correzione dimostrata della causa. Una lettura mapping isolata non basta a diagnosticare Map bloccato.
2. Rendere lo stato della cattura specifico del singolo run prima di usarlo per il recupero: il Target può essere riutilizzato mentre un vecchio thread termina. Applicare poi un recupero limitato e motivato dalla causa osservata, mantenendo tutte le verifiche d’identità; niente retry infiniti o nuovi contesti per tentativi.
3. Verificare la coerenza dei timestamp QPC/WGC nella VM prima di usare guestFrameAgeAtSendMilliseconds per conclusioni. Gli altri tempi locali e il conteggio callback sono già visibili in status.frameTimings; il chunk256KiB riduce i passaggi ma non ha un confronto quantitativo di latenza valido. Valutare compressione/delta soltanto se le misure ne motivano il costo.
4. Dopo la correzione, una breve prova nelle finestre reali: avvio Impostazioni dal launcher, ricerca/testo, resize, popup e riconnessione; riusare le evidenze già valide di Blocco note e icone, senza ripetere matrici estese.

Creality resta rinviato. Scorciatoie Mac rimangono lavoro futuro. Non riprendere pulizie Parallels, UAC, cambi ISO o driver senza una nuova necessità concreta.


## VM corrente — Windows IoT LTSC installata dall’utente, 22 ottobre 2026

L’ultima richiesta sostituisce la base Windows precedente: usare la nuova VM UTM Windows 11 IoT LTSC e installarvi guest tool e driver necessari. L’utente autorizza esplicitamente la rimozione delle vecchie VM per recuperare spazio; il precedente vincolo di conservare quelle originali non si applica a questa pulizia. Conservare invece la nuova sorgente UTM e lavorare su una copia APFS indipendente, con TPM e contenuto UEFI preservati.

La macchina corrente di Perpendicular deriva ora da questa nuova installazione. Il bootstrap aggiunge soltanto il bridge Rust attuale e i pacchetti ARM64 firmati di rete e grafica, senza vecchi agenti, sharing, impostazioni RDP o workaround grafici ereditati. Questo cambio di sistema non dimostra risolti i problemi generali di WinUI, cattura o renderer. Dopo una breve verifica di avvio, collegamento e singola app riprendere gli incrementi piccoli di stabilità/fluidità sopra indicati, partendo dalle nuove evidenze.


## Obiettivo attivo — utilizzabilità IoT e controllo dei processi, 22 ottobre 2026

L’utente segnala che il prodotto è ancora inutilizzabile: aperture inaffidabili anche del terminale, lag e stato dei processi errato nel launcher. Continuare sulla sola copia più recente Windows 11 IoT, usando i guest tool per i comandi e REA quando una domanda sui binari/runtime lo richiede. Il precedente successo puntuale di Notepad non supera questa segnalazione.

Risultati osservabili da completare in piccoli incrementi:

1. Distinguere processo vivo, avvio pendente, finestra disponibile e cattura interrotta nel launcher Swift. Mostrare i processi dell’utente Windows e consentire chiusura normale delle finestre o terminazione esplicita del singolo processo attraverso il guest agent, verificandone PID, creazione, utente e sessione. La disconnessione rende lo stato sconosciuto.
2. Riprodurre apertura/input del terminale e di una normale app, separando mancata attivazione, rendering guest e cattura. Intervenire su driver/acceleratore e trasporto soltanto sulla causa osservata; preservare la sorgente IoT, mantenere un ritorno praticabile prima di cambiare runtime.
3. Ridurre lag e copie nel percorso reale, con una breve verifica nell’app finale e limiti espliciti; commit e push degli incrementi conclusi. Non considerare concluso l’obiettivo generale finché avvio, interazione e recupero non sono utilizzabili.

### Incrementi verificati di questa ripresa

Pubblicati controllo processi/stati e compressione LZ4 indipendente dei frame; il terminale riceve comandi dopo il click, si ridimensiona e sopravvive alla riconnessione. La compressione riduce il traffico della console osservata da12,1MB a circa101KB, con encode/decode locali espliciti: non è una misura generale di latenza. Il menu Win32 #32768 ha ora un percorso circoscritto senza device WGC aggiuntivo e clic verificati; i dialoghi restano sul percorso normale.

L’obiettivo resta attivo. Prossimo risultato osservabile: rendere disponibile il dialogo Open #32770 della Notepad attuale, che viene creato da File→Open ma WGC rifiuta con0x80070057 prima del primo frame. Separare capacità/affinità/owner della superficie dal rendering driver e dalla creazione del device; usare execute per le poche query mirate. Non ricominciare importazione o pulizia VM, non aggiungere retry infiniti né estendere GDI a tutte le finestre per nascondere il guasto. Il desktop resta il recupero osservato, con possibile attesa al primo frame.

Restano poi allineamento DPI250% contro il Mac e attivazione iniziale prima del primo click. Il probe hardware VirtIO3D continua a riuscire, ma WinUI e affidabilità generale del renderer non sono certificati. Il sorgente matching del proxy conserva un recvmsg senza timeout; un campionamento di2 soli punti non dimostra uno stallo attuale né giustifica una patch indiscriminata. Prima di cambiare runtime/driver conservare checkpoint e versione precedente. Evidenze, errori intermedi e build in VERIFICATION.md.

### Dialoghi classici — incremento successivo verificato

Il rifiuto WGC è stato isolato alla creazione dell’item per HWND owned, prima di GPU/readback/trasporto. I dialoghi #32770 della stessa Notepad ora sono catturati mediante una sola ammissione APPWINDOW transitoria, con owner e affinity verificati e ripristino immediato prima della sessione. Salvataggio in un nuovo file Temp, lettura diretta del testo e successiva apertura dal dialogo Mac riusciti. Un Open già aperto sopravvive alla riconnessione con lo stesso identificatore anche con la sincronizzazione finale per-HWND. Guest c782a882a6fc nel servizio e nel pacchetto; frontend ordinario aperto, VM e sorgente UTM conservate.

Il prossimo incremento riparte da DPI/scala e avvio/input senza interventi manuali, verificando una normale app e una superficie WinUI sulla IoT attuale. Non ripetere l’intera verifica dei dialoghi finché il percorso pertinente non cambia. Restano driver3D, eventuali stalli e costo WARP/readback da migliorare sulla base di un guasto o misura concreta; la sola disponibilità di Save As/Open non completa l’obiettivo generale. La sincronizzazione introdotta riguarda solo la creazione della stessa finestra e non autorizza nuove code globali o astrazioni per backend futuri.


### Avvio con PID e nuova priorità grafica

La prova IoT di Settings ha riprodotto un processo vivo non associato dopo un'attivazione Shell con PID zero. Le app con identità di pacchetto verificata usano ora ActivateApplication, con PID, AUMID e creazione autenticati; le altre voci conservano Shell. Eliminata anche l'attesa di sola osservazione che impediva un nuovo avvio dopo un processo terminato. Il launcher non deduce più «processo terminato» dall'assenza di un handle Shell. Verifiche e versioni finali sono in VERIFICATION.md.

La priorità successiva è il ciclo di vita delle risorse del broker Native3D: il registro a256 slot e la conservazione delle tombstone possono chiudere la cattura e rifiutare nuovi contesti, con desktop nero. Non basta aumentare la tabella; verificare ritiro delle risorse, pacchetti e lease ancora in corso, riuso degli ID con epoch, e la relazione fra cattura del desktop e ammissione del rendering. Non attribuire automaticamente a questo limite tutti i glifi WinUI assenti: nel segmento fresco della prova compaiono anche generici Not implemented senza saturazione. Risultato osservabile richiesto: Settings con testi e input utilizzabili e desktop di recupero ancora disponibile dopo la normale apertura/chiusura. Un controllo mirato del ciclo di vita e una breve prova reale sono sufficienti per il prossimo incremento; niente grandi harness.

La IoT è stata spenta regolarmente, conservata in un checkpoint privato a disco fermo e riavviata sul medesimo runtime. Sorgente UTM e file di prova salvato conservati. Prima di nuovi interventi al renderer utilizzare quel checkpoint e tenere il runtime precedente. DPI250%, attivazione/input iniziale e WARP/readback restano aperti; nessun completamento dell'obiettivo generale dichiarato.


### Direzione attiva dell'utente — WGC + GPU sul Blocco note classico

Indicazione successiva del22 ottobre: proseguire con Windows Graphics Capture e GPU, usando per ora applicazioni classiche e in particolare il vecchio Blocco note; escludere WinUI da questa fase. Il risultato resta affidabilità e bassa latenza nell'app reale, con avvio, input, menu/dialoghi, resize e riconnessione. Verificare il dispositivo effettivamente usato dalla cattura, non soltanto un probe Direct3D separato. Distinguere acquisizione GPU, readback CPU, trasporto e presentazione Metal; non descrivere come zero-copy un percorso che legge i pixel.

Inventario confermato al cambio di obiettivo: un solo monitor virtuale DISPLAY1 su VirtIO GPU3D,2940×1912 e240DPI (250%); QEMU max_outputs=1 e confronto geometrico limitato al principale Mac. Il requisito futuro rimane posizione, dimensioni e scala1:1 con gli schermi reali, tramite monitor virtuali corrispondenti o adattamento del monitor VM allo schermo Mac contenente la finestra. Non implementare o dichiarare multimonitor in anticipo; non cambiare il monitor a ogni resize dell'app senza motivazione e verifica delle altre finestre.

Primo incremento WGC+GPU verificato: cattura del Blocco note e del suo Open sul dispositivo hardware effettivo, con staging riusabile a fasce per superare il Map pieno fallito. Riapertura del file salvato, resize reale e recupero dello stesso documento dopo Quit/riapertura del frontend riusciti nel pacchetto finale. Conservati errori intermedi e tempi per fase in VERIFICATION.md. Rimangono readback e copie CPU: il costo è variabile e il solo campione più rapido non certifica la bassa latenza.

L'obiettivo resta attivo. Il prossimo intervento deve ridurre un costo o guasto concreto: ciclo di vita delle risorse del broker (saturazione nuovamente osservata), oppure attese Map/copia durante aggiornamenti della finestra. Prima di cambiare runtime mantenere checkpoint pulito e versione precedente; non limitarsi ad aumentare il registro. Conservare il percorso WGC hardware ora funzionante, con poche verifiche reali sul Blocco note. WinUI rimane escluso. Riconnessione e DPI non sono ancora1:1 e la geometria Mac precedente non è ripristinata esattamente.

Incremento successivo: ritiro delle risorse distrutte mediante conferma del produttore e ACK delle copie immutabili, con riuso degli slot e nuove epoch, senza aumentare256. La build finale con controllo host3 è nella IoT11931; nuova riga salvata nel Blocco note, resize, cambio/ripristino del display, desktop di recupero e riconnessione allo stesso documento verificati.21 ritiri reali,9 di sorgenti già granted; prove e un candidato fallito al boot registrati in VERIFICATION.md. Non attribuire con certezza quel fallimento alla corsa di revoca corretta nel controllo C. Rimangono registro COM conservativo, uscite del produttore e affidabilità generale da affrontare su evidenze nuove; non ricominciare cicli estesi di boot o stress dopo questa riuscita mirata.

Prossimo passo utilizzabile: correggere l'ammissione delle superfici ausiliarie che produce ancora un banner di errore per CreateForWindow mentre Blocco note e Open funzionano, evitando device GPU creati per ombre non utilizzabili senza nascondere errori del main/dialogo. Poi ridurre un costo concreto Map/copia nel WGC hardware, mantenendo risoluzione e contenuto corretti. Nessun completamento o guadagno generale di latenza dichiarato da questo ritiro di metadati.

Incrementi seguenti: ammissione dell'item prima del device GPU, esclusione delle sole SysShadow decorative e corretta portata degli errori tooltip verificati e pubblicati. Riuso esclusivo delle allocazioni BGRA mediante Arc implementato nel pacchetto e nel guest: due aggiornamenti della stessa finestra mostrano copia9ms→circa1,6ms, con readback ancora completo e Map variabile. Non confondere questi campioni locali con latenza complessiva o affidabilità raggiunta.

Prossima domanda precisa: perché un main riconnesso mentre Open è già presente resta senza primo frame, pur con dialogo leggibile e broker aperto? La chiusura del dialogo e un RedrawWindow singolo non bastano; una nuova cattura del solo main produce un primo frame incompleto e il clic reale seguito da selezione ripristina il contenuto. Distinguere callback WGC, eventuale Recreate che scarta il primo frame, ordine d'ammissione del dialogo e sovrapposizione fra run. Raccogliere pochi dati per il singolo guasto prima di scegliere una correzione, senza restart ripetuti o retry infiniti. Anche focus/attivazione iniziale resta aperto; il percorso del clic già alza la finestra senza attivarla prima dell'input, mentre la sola attivazione usa SetForegroundWindow. Non assumere ancora quale di questi passaggi spieghi il frame incompleto.

### Priorità aggiornata — geometria1:1 in punti Mac

Nuova richiesta dell'utente: correggere ora posizione e dimensioni fra Windows e Mac, provando1470×956 pixel nel guest sul principale Mac1470×956 punti. La densità Retina resta nel presenter Metal; non richiede di renderizzare il desktop Windows a2940×1912. Usare un'unica trasformazione per immagini, input, drag/resize e superfici figlie. Verificare leggibilità reale, dimensioni/posizione dopo un gesto e riconnessione. Il confronto geometrico non deve dipendere dall'uguaglianza fra DPI Windows e backing scale Mac: sono grandezze distinte.

La prima prova di cambio risoluzione porta la IoT a1470×956 e96DPI automaticamente. Resta da riservare in Windows l'area della barra menu Mac, che altrimenti causa uno spostamento implicito di33 punti in AppKit. La cattura della sessione già accesa era indisponibile prima della prova: broker chiuso dal contesto7 a15:20:38, messaggio207/status94 in imported, e successivi device GPU rifiutati. Conservare questo fallimento come problema distinto; un riavvio regolare necessario alla verifica della geometria non ne certifica la soluzione. Il requisito multimonitor rimane successivo: il guest ha sempre un solo monitor, riferito al principale Mac.

Incremento geometrico verificato e integrato:1470×956/96DPI, un pixel guest per punto Mac, margine menu33 punti confermato nel guest senza SENDCHANGE (la notifica lo annullava). Drag100×75, resize100×50, menu, client del dialogo Open e riconnessione mantengono i rettangoli corrispondenti; documento precedente leggibile e intatto. Presenter Metal Retina conserva l'ingrandimento2×, con testo più morbido del rendering nativo a densità doppia. Build e payload finali ed evidenze in VERIFICATION.md. Non estendere questa prova ai monitor esterni o alla riconnessione con Open già presente. Il guasto imported del renderer precedente resta distinto e aperto; non dedurre affidabilità generale dal riavvio riuscito.

### Correzione successiva dell'utente — ripristinare la densità Retina

L'utente giudica sgranata la prova1470×956 e chiede di riportare Windows al doppio delle dimensioni logiche Mac. Questa indicazione sostituisce la precedente scelta di ridurre la risoluzione: sul principale1470×956 punti richiedere2940×1912 pixel, mantenendo geometria in punti e conversione esplicita2:1. Anche l'area utile viene espressa in pixel guest, quindi il margine menu diventa66 pixel. Windows configurato al200% attraverso le impostazioni Display,192DPI confermati; non confondere risoluzione doppia con controlli grandi il doppio sul Mac. Conservare indipendenza fra verifica geometrica e DPI Windows.

Percorso finale verificato sul Blocco note classico: testo preservato e riaperto, immagine a densità nativa, Open utilizzabile, resize con rettangoli2:1 esatti e ripristino limitato del margine quando la shell ricalcola l'area utile. Build ricompilata e aperta; dettagli in VERIFICATION.md. Rimangono primo frame lento/inizialmente bianco e guasto del renderer che aveva già chiuso la sessione precedente: non sono risolti da questa modifica della risoluzione. Nessun nuovo driver o payload guest; un solo monitor virtuale.

### Comandi VM richiesti nell'app Swift

Richiesta successiva dell'utente: aggiungere avvio e arresto forzato di Windows nell'app. Esporre due comandi visibili nel launcher e nel menu, distinguendo processo VM vivo, guest collegato, VM spenta e controllo non verificabile. Il guest agent non deve essere necessario all'arresto forzato. Confermare la perdita potenziale delle modifiche non salvate nel comando distruttivo; non presentare un comando accettato come arresto completato. Non avviare una seconda VM quando il controllo non risponde.

Incremento verificato: annullamento della conferma senza arresto, arresto QMP della sola VM autenticata con UUID e PID del peer, processo realmente uscito e Avvia abilitato; riavvio dallo stesso launcher e guest ricollegato. Comandi e osservazione asincroni, senza le attese bloccanti precedenti di avvio; normale Spegni conservato nel menu. La conferma è legata al processo osservato, così non può colpire una nuova istanza subentrata. Nessun kill di PID letto ciecamente da file; se il controllo host è indisponibile si mostra il limite. Non attribuire a questi controlli una correzione dei guasti grafici. Evidenze e limiti in VERIFICATION.md.


### Priorità aggiornata — driver, tutte le app e input Mac

La richiesta successiva riporta WinUI nel perimetro: proseguire su stabilità del driver e compatibilità di tutte le app, senza escluderle per il framework. Supera quindi il precedente rinvio di WinUI e delle scorciatoie Mac. La texture finale correttamente prodotta resta l'input della cattura; composizione, condivisione, lettura e produzione della texture sono capacità da verificare separatamente. Conservare2940×1912/200% e la trasformazione geometrica2:1 sul solo monitor virtuale attuale.

Correggere anche Delete, scorciatoie Mac e trasferimento esplicito del testo negli appunti fra i sistemi. Consultare il vecchio progetto per queste precise funzioni; non importarne automaticamente motore o protocolli. L'utente chiede poche prove dei tasti e segnalerà personalmente ulteriori difetti: una breve prova completa basta, senza matrice di shortcut. Nessun completamento generale sulla base di una sola app riuscita.

Incrementi di questa ripresa: eliminato il registro COM importati a256 elementi tramite marker legato alla risorsa; backend effettivo verificato e nuova coppia renderer/server installata. Delete e trasferimento esplicito del testo Mac↔Windows verificati con un giro nel Blocco note; principali shortcut Mac implementati senza una matrice di prove. Settings presenta testi e icone con WGC hardware, ma la sua navigazione incontra rifiuti di occlusione/correzioni geometriche e perdita della relazione fra finestre. Limitata la correzione automatica alla prima immagine visibile e a una sola richiesta per display; consentita riattivazione esplicita dei pacchetti ancora vivi senza finestra. Non dichiarare risolto WinUI.

Una riconnessione successiva riproduce Map0x887A0005/reason0x887A0020 senza broker chiuso. Il prossimo controllo circoscritto riguarda la protezione multithread dell'immediate context condiviso con il pool WGC free-threaded: manca nel codice attuale, ma la sua relazione con il fault va verificata sul dispositivo effettivo. Conservare errori e percorso funzionante; nessun nuovo ciclo esteso di boot o test tasti.

La protezione multithread è ora effettivamente attiva ma il Map hardware continua a fallire nella prova. Per quel solo device loss è disponibile una sessione WGC WARP di recupero, una volta per run, con errore hardware conservato e avviso distinto dalla cattura interrotta. Blocco note torna leggibile e si riconnette senza riavviare Windows; l'ultimo screenshot conserva un difetto nel titolo. Windows rimane sul driver3D e il presenter Mac su Metal, ma la lettura della finestra in recupero è software. Non considerare raggiunto l'obiettivo GPU/latenza o il supporto universale.

Settings nuovo resta vivo senza una finestra ospitata ammessa; nessuna nuova matrice di test o aggancio debole per nasconderlo. Il desktop consumer appena aperto non svuota i2 snapshot pendenti osservati: domanda successiva precisa sul completamento del produttore Native3D e relazione con Map/device loss, conservando questo percorso utilizzabile e i fallimenti. Non ripartire da test tasti, importazione VM, riduzione della risoluzione o boot ripetuti. Evidenze, modalità reali e limiti finali in VERIFICATION.md.


### Ripresa del23 ottobre — affidabilità e fluidità driver/GPU

Obiettivo esplicito: aumentare affidabilità e fluidità del percorso grafico, rivalutando anche le soluzioni esistenti. Obiettivo persistente attivo; una miglioria al presenter non conclude il lavoro sul driver. Conservare Retina2940×1912/200%, documenti, sorgente IoT e recupero software circoscritto. WinUI resta nel perimetro, senza promettere compatibilità universale.

La rivalutazione parte da tre domande separate: produzione/completamento della texture; costo e correttezza del readback WGC; attese/allocazioni nel presenter. Nella sessione corrente WGC hardware funziona pur con due snapshot pendenti e zero letture del consumer desktop: questi contatori da soli non provano uno stallo o la causa di un device loss. Signal del backend incluso contiene già la chiamata virtuale Flush; non aggiungere un secondo invio sulla sola ipotesi che manchi.

Primo incremento: device e pipeline Metal condivisi fra presenter, con compilazione una volta per processo dopo una riuscita; code, immagini e lease restano per finestra. Build, firma, riconnessione del documento, input e resize verificati. Nessun guadagno numerico di latenza attribuito a questa modifica. Un dialogo di conferma ha ancora un primo frame bianco ed è stato annullato; il problema rimane aperto.

Prossimo risultato: isolare quel primo frame bianco confrontando texture catturata e immagine presentata della stessa superficie; poi valutare una lettura WGC a due staging limitati soltanto se la misura conferma che sovrapporre le copie riduce le attese senza reintrodurre Map falliti. È un candidato, non una capacità verificata. Confronto Parallels tramite REA su una domanda circoscritta quando serve; nessuna architettura ereditata o nuovo consumer desktop nascosto per svuotare i contatori.


Incremento seguente del23 ottobre: conferma #32770 isolata a un primo frame ricevuto interamente trasparente, prima di Metal. Una singola invalidazione asincrona del solo dialogo, dopo quella prima lettura vuota e con identità/visibilità ancora valide, produce il frame completo; apertura e riconnessione con conferma già presente verificate nel pacchetto e su WGC hardware, senza comandi manuali o riavvio Windows. Primo frame conservato, nessun retry continuo, nessuna estensione ai main o cambio di backend. Guestb1047ebf3b5b nel servizio e nel bundle. Dettagli e tentativi falliti in VERIFICATION.md.

La causa interna fra produzione DWM, WGC e readback non è ancora dimostrata; il recupero non equivale alla sua eliminazione. Il main riconnesso mentre la conferma è aperta può ancora iniziare trasparente e recupera dopo Escape. Anche il desktop di recupero osservato nero resta aperto. Proseguire sul costo Map del documento con un confronto piccolo della sovrapposizione fra copia e lettura, oppure sulla produzione della texture del desktop se emerge un guasto concreto; nessuna nuova matrice o serie di boot per certificare l'affidabilità.


### Lettura WGC a fasce sovrapposte —23 ottobre

Integrato un percorso hardware a due staging che si dividono il precedente budget dimensionale di4MiB; superfici piccole e WARP mantengono un solo staging. Copia della fascia seguente sovrapposta alla lettura CPU, riuso soltanto dopo Unmap e nessuna coda fra frame. Campioni sul documento2340×1446: readback16,93ms nel precedente→9,58/13,87ms nella variante finale, con variabilità e limiti in VERIFICATION.md. Resize con ultimo blocco parziale e riconnessione dal pacchetto finale riusciti sullo stesso documento e su WGC hardware. Guest143938a67e35 installato e nel bundle.

Il candidato iniziale con due staging da4MiB ciascuno NON è stato promosso: in una successiva apertura del dialogo compare il device loss, seguito da WARP. Il confronto con il precedente e la variante a budget invariato non prova la causa, ma motiva la scelta che non raddoppia l'allocazione. Il dialogo può inoltre restare trasparente anche con2frame e repaint, riprodotto sia nel baseline precedente sia nella variante finale: corregge la portata della riuscita del turno precedente. Non aggiungere altri retry per dichiararlo risolto.

Prossimo incremento prioritario: distinguere readiness, lease e identità/batch dei due snapshot pendenti del desktop, con una lettura circoscritta del broker realmente avviato. Al momento pending2 e completed0 non spiegano da soli il guasto; non aumentare tabelle, non aggiungere un consumer desktop nascosto, non proseguire il tuning delle fasce dopo la riuscita mirata. Restano desktop nero, dialoghi intermittenti, device loss e compatibilità WinUI; il solo documento funzionante non completa l'obiettivo generale.


### Ritiro degli scanout obsoleti sul medesimo produttore —23 ottobre

Corretto il broker: copie pronte e senza lease di una risorsa non più selezionata vengono ritirate anche quando il worker non cambia. Controllo C sul codice reale fallisce prima e passa dopo, conservando lease e lavori GPU incompleti. Il nuovo pending_frames distingue readiness, identità/batch, lease e corrispondenza con la selezione senza consumare eventi. Coppia renderer/server ricompilata preservando QEMU, backend e driver.

Nella prova del pacchetto, desktop visibile, frame consegnato/ACK e coda vuota; dopo avvio di Notepad, Open e caricamento del testo sintetico da un nuovo Temp, desktop nuovamente aggiornato e cambio67→66 sullo stesso worker7,3consegne/ACK e nessun pending o broker chiuso. Main su WGC hardware. Dettagli e limiti in VERIFICATION.md. Prima del recupero un attach LLDB fallito è seguito dall'uscita della VM: registrato come incidente, conservato lo stato offline senza ripristino e fatto un solo nuovo avvio. Non dichiarare shutdown pulito, affidabilità generale o recupero automatico del testo non salvato.

Prossimo incremento: evitare nuove copie scanout quando il publisher non ha un consumer utilizzabile. Il nuovo broker ha ricevuto305copie prima della prima apertura del desktop: molte sono ora ritirate correttamente, ma restano lavoro GPU evitabile. Mantenere il pump per ACK/ritiri e le copie già in corso, richiedendo un frame aggiornato alla successiva apertura del desktop. Verifica minima: aggiornamenti della singola app senza copie desktop crescenti, poi desktop aggiornato e nuovamente richiudibile. Restano device loss, dialoghi intermittenti e WinUI; non ripetere debugger attach o serie di boot e non ridurre l'obiettivo al solo desktop recuperato.
