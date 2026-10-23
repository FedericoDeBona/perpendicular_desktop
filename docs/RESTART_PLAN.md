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

Far corrispondere posizione e dimensioni di ogni finestra Mac alla relativa finestra Windows. Il Mac risponde immediatamente al gesto. Per il resize vale la richiesta aggiornata del 23 ottobre: anteprima locale delle sole dimensioni durante il gesto, unico invio a Windows al rilascio; al rilascio il contenitore Mac assume subito le dimensioni scelte sotto la copertura con icona e spinner, e mostra il contenuto quando è presentato il frame della geometria confermata. Per il movimento restano gli aggiornamenti controllati durante il gesto. Rispettare i minimi e le dimensioni realmente accettate dall'app.

Durante il gesto mantenere utilizzabile il contenitore Mac; al termine riconciliare la geometria con quella accettata da Windows. Una risposta in ritardo o appartenente a una connessione precedente non deve annullare il movimento più recente. Se un'operazione fallisce, terminare il gesto, rilasciare i pulsanti e tornare a uno stato utilizzabile, mostrando l'eventuale errore.

Conservare i controlli Windows delle finestre principali. Menu, tooltip e popup rimangono associati al proprietario; i veri dialoghi conservano i controlli Mac previsti. Mouse e tastiera devono restare utilizzabili dopo drag, resize, cambio focus e riconnessione. Il desktop completo rimane raggiungibile per manutenzione e recupero.

Evolvere la base attuale senza revert indiscriminati: conservare recupero dell'input, classificazione delle superfici e controlli utili. Superare i limiti provvisori di geometria, rispettando la successiva scelta esplicita del resize al rilascio con anteprima locale.

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


### Copie desktop solo con domanda del consumer —23 ottobre

Integrato in QEMU un solo update_pending durante vista chiusa o slot del publisher pieni. Al ritorno di capacità viene richiesto un frame fresco; pump, ACK e lease in corso restano attivi. Runtime69c236476db8 preserva renderer16afc0437449, backend e guest143938a67e35. Controllo delle funzioni reali tick/flush fallisce prima e passa dopo, senza nuova suite o dipendenze.

Nella prova reale: vecchio runtime desktop chiuso527→542copie dopo selezione del testo; nuovo runtime0copie/0allocazioni prima di aprire il desktop, anche con cambi display e apertura WGC. Dopo chiusura della vista242→242durante Command-A, poi una sola nuova copia alla riapertura243, selezione corrente visibile e ACK, pending0. Il documento resta su WGC hardware. Shutdown ordinario terminato oltre il primo timeout, checkpoint a disco fermo e unico nuovo avvio; dati e runtime precedente conservati. Windows ha scelto nuovamente250% dopo il modo iniziale di boot, riportato200% tramite Settings/192DPI confermati: persistenza tra boot ancora da chiarire.

Limiti conservati: prima Command-O rifiutata fino al clic nell'app; nuovo Open fallisce CreateForWindow after dialog admission0x80070057 prima del device. Il desktop di recupero ha permesso di aprire il file salvato, ma questo non certifica il dialogo Mac. Prossimo passo: raccogliere pochi dati del solo rifiuto di ammissione (identità, owner, stili, cloaking e prontezza della composizione) prima di cambiare il percorso. Non ripetere tuning staging o test di copie ormai riusciti; restano driver/device loss e compatibilità generale WinUI nell'obiettivo attivo.


### Ammissione dei dialoghi osservabile —23 ottobre

Guest47fc492c8581 conserva una traccia compatta al primo rifiuto WGC, sia dopo ammissione riuscita sia sul fallimento prima del device. Identità/owner/stili originari, HRESULT, snapshot dopo ripristino con cloaking/affinity/DPI; nessuna nuova attesa o tentativo. DWM abilitato non prova readiness. Installazione indipendente verificata, pacchetto finale riaperto sulla stessa VM, Open hardware con stili ripristinati e tooltip rifiutato con errore conservato. Rifiuto intermittente del secondo CreateForWindow di Open non riprodotto: resta aperto, non introdurre FRAMECHANGED sulla sola ipotesi. Dettagli e tentativi falliti in VERIFICATION.md.

Il main riconnesso durante un dialogo modale resta0frame anche dopo Escape/Command-A, mentre il desktop conferma testo e input corretti. Una riconnessione senza dialogo recupera il main hardware con la stessa identità, senza riavviare Windows. App lasciata leggibile; non è recupero automatico. Prossimo passo circoscritto: distinguere avvio/callback WGC del main disabilitato, assenza di callback e frame scartati usando i dati per-run esistenti. Conservare la diagnostica per il prossimo rifiuto di Open; niente nuovi loop o matrice di prove. Obiettivo GPU generale attivo, device loss e WinUI ancora da risolvere.


### Ripartenza del main dopo il dialogo modale —23 ottobre

Contatori per-run distinguono callback, acquisiti, ricreazioni e sessionStarts. Con il precedente avvio immediato, main disabilitato da Open:0callback/0acquisiti/0frame anche dopo Escape e conferma IsWindowEnabled=true; dialogo15callback/15frame. Non è quindi un problema del readback di frame già arrivati. La causa interna del mancato avvio non è ancora dimostrata.

Guest955f6ef66070 attende prima di allocare item/device/pool soltanto per quel main con #32770 visibile, owner diretto e identità di processo/sessione verificata. Alla chiusura parte una sola sessione; non modifica le finestre e non riavvia catture attive. Candidato13frame hardware dopo Escape, pacchetto finale riconnesso e poi18frame hardware dopo Escape senza altra riconnessione. Stesso documento e VM, frontend9efacf137791, build e firma riuscite; dettagli e tentativi falliti in VERIFICATION.md.

L’immagine del main durante la riconnessione con dialogo ancora aperto rimane un limite; il miglioramento riguarda l’avvio automatico dopo la chiusura. Nessuna estensione automatica a WinUI/modal di altri processi o owner indiretti. Dopo questo passaggio verificato proseguire con un solo percorso Settings nel launcher e nelle finestre individuali, separando dispositivo, scoperta dell’host e cattura; conservare main e recupero desktop. Restano device loss, ammissione intermittente e compatibilità generale. Non ripetere prove di staging, copie desktop o boot già riuscite.


### Evidenze WinUI e stderr del driver —23 ottobre

Settings dal launcher mostra System su WGC hardware e naviga a Display dopo attivazione tramite tastiera; una superficie Mac in primo piano può ancora essere coperta in Windows. Tentativo di attivazione prima del click scartato perché non dimostra un beneficio affidabile. Sul desktop Display è completa, nella cattura individuale mancano zone; PNG ricevuti prima di Metal confermano colori mancanti già nei pixel, con alpha255. WGC dichiara ReportOnly0 anche sui frame incompleti. Non forzare alpha, non ricostruire delta o aggiungere repaint sulla sola ipotesi.

Guest a5baaf2b4769 installato e nel pacchetto1e618976f7ee: contratto di immagini complete osservabile e stderr nativo del driver conservato privatamente, massimo512KiB per worker e drain dopo il cap. Messaggi reali Neptune e isolamento di execute verificati; driver/runtime invariati. REA statica del DLL ARM64 pinned individua controlli Map/slot e watchdog/ring, senza prova del ramo responsabile. Evidenze/hash/limiti in VERIFICATION.md e snapshot REA privato; nessun attach alla VM o nuova installazione di tool. Il device loss0x887A0005/reason0x887A0020 resta riprodotto; il log deve ora distinguerne i casi concreti.

Nuova causa separata: desktop nero consegnato/ACK e WGC0callback dopo oltre15min senza input, contro timeout display AC5min. Richiesta display temporanea12s fa ricomparire desktop e documento senza reboot; sessioni WGC già partite a display spento rimangono senza callback. Prossimo risultato: richiesta display attivo prima delle catture, limitata al collegamento Mac e rilasciata alla disconnessione, senza cambiare policy o blocco schermo. Distinguere questo recupero da Map e dai pixel WinUI incompleti, non ancora risolti. Nessuna nuova serie di boot o tuning staging.


### Display attivo durante lo streaming e nuovo errore concreto —23 ottobre

Guest986610dbc6b4 richiede ES_DISPLAY_REQUIRED sul thread del collegamento prima delle catture, ripristinando il precedente stato alla disconnessione. Nessun cambio di policy, screensaver/blocco o SYSTEM_REQUIRED. Richiesta temporanea recupera il desktop nero dopo l’inattività; build finale acquire/release/restored=true e ripartenza delle catture verificate. Documento leggibile, runtime/driver/VM invariati. Tentativo di verifica5min senza input invalido perché il contatore ha registrato input durante l’attesa: non ripetuto e non contato come riuscita. Durata senza input resta da osservare; dettagli e hash in VERIFICATION.md.

Il log driver appena introdotto registra ora, in corrispondenza del Map0x887A0005/reason0x887A0020, RES_INFO0xc000009a, allocazione shmem16MiB fallita e pool_alloc slot0 di circa2MiB fallito. Main e Settings attualmente riprendono con WARP, non hardware; non dichiarare risolta la GPU. Sorgente KMDv0.3/commit769e75c restringe quel codice a userVa assente (piazzamento BAR o mappatura/MDL/bookkeeping); la mappatura host sincrona fallisce con altro stato. Prossimo intervento preciso: distinguere quelle cause e controllare rilascio/occupazione effettiva delle finestre condivise. Non aumentare budget o diminuire risoluzione sulla sola stringa, non creare altri contesti diagnostici o serie di boot. UMD separato in osy/virtio-win-mesa, DLL pinned e snapshot REA conservati. Restano pixel WinUI e focus; obiettivo generale attivo.


### Apertura condivisa GPU adeguata al caso Retina —23 ottobre

Misurato il BAR reale da256MiB senza debugger: con le due app il massimo spazio contiguo non mappato è16.613.376byte, insufficiente per il pool16.777.216che il log nativo dichiara fallito. Chiudere Settings libera60.989.440byte, ma una nuova cattura hardware del solo main riporta il massimo sotto16MiB e fallisce ancora. I dati sono limiti inferiori dell'occupazione, non un'inventario completo della bitmap KMD; non attribuiscono ogni device loss precedente alla stessa causa.

Portata a512MiB la sola apertura del dispositivo 3D, con checkpoint offline dopo ACPI ordinario e un nuovo boot. Runtime/driver/guest invariati. Pacchetto finale: Notepad e Settings contemporaneamente su hardware, Open carica il testo sintetico, massimo intervallo non mappato256MiB. Una riconnessione conserva le due identità e riparte hardware, memoria mappata scende invece di crescere; log reale senza i precedenti errori di allocazione. Dettagli, misure e lettura fallita del file di log registrati in VERIFICATION.md. Non è una prova prolungata o di assenza generale di leak.

Mantenere questo percorso utilizzabile. Restano etichette/testi WinUI inizialmente mancanti, prima attivazione, dialoghi intermittenti e affidabilità generale. Il prossimo confronto deve isolare il contenuto prodotto/catturato rispetto al readback individuale, con una breve prova reale e senza aumenti ulteriori di memoria, nuove serie di boot o benchmark. Il solo passaggio256→512verificato non completa l'obiettivo GPU generale.


### Confronto WinUI dopo il margine BAR —23 ottobre

Nella stessa esecuzione hardware512MiB, la pagina HDR di Settings manca delle etichette della sidebar sia nella finestra individuale sia in Show Windows. La seconda pressione durante il cambio pagina ha aperto HDR; nessuna impostazione HDR cambiata. Questo caso non è esclusivo del readback individuale: rivalutare la produzione/composizione WinUI e il backend effettivo prima di introdurre altri adattamenti WGC. Non annulla il precedente caso Display completa sul desktop/incompleta nella cattura. Nessuna causa di blending, simbolo opzionale o decoder ancora provata; desktop richiuso, percorso hardware e documento conservati. Dettagli in VERIFICATION.md.


### WinUI senza WGC e messaggi del frontend driver —23 ottobre

Vista desktop indipendente e visibile costruita con i componenti correnti, senza GuestBridge: dopo Quit and Keep Windows il worker non si ricollega e le catture rilasciano circa19MiB mappati. La nuova Settings aperta da Explorer appare completa su Display ma perde etichette passando a HDR, ancora senza WGC. Questo è contenuto nuovo, non solo un frame vecchio. Pacchetto normale ripristinato, documento conservato e catture hardware operative; nessun boot o cambio di driver. Dettagli e tentativi non conclusivi in VERIFICATION.md.

REA del DLL installato conferma rotazione delle risorse, ricreazione viste e callback dei binding; non è assenza dell'intero passaggio e non prova che le sue singole operazioni riescano. I messaggi Triton usano OutputDebugStringA, distinto dallo stderr Neptune. Collector DBWIN temporaneo e limitato, rifiuto di lettori già presenti, una nuova Settings osservata per30s:62messaggi selezionati, marker di controllo riuscito, nessun errore/STUB in quelle righe. Le superfici condivise a un byte vengono confermate A8_UNORM nel log host; non attribuite automaticamente al testo mancante.

Prossimo passo: identificare le funzioni dei tre errori generici Not implemented nel backend reale, con diagnostica una tantum per operazione; poi correggere soltanto un comportamento dimostrato pertinente. Tenere distinta questa evidenza dalla mancata emissione di STUB Triton. Niente adattamenti WGC, aumento memoria o cambio indiscriminato di driver; le A8 condivise e la conservazione degli aggiornamenti restano una domanda precisa. Nessun collector o viewer diagnostico lasciato attivo, percorso ordinario hardware conservato.


### Errori backend identificabili e prova A8 circoscritta —23 ottobre

Backend1a704afafdb1 aggiunge soltanto i nomi a cinque errori, con frequenza e HRESULT invariati. Ricostruzione ripetibile da input verificati e su copie private. Unico boot dopo ACPI/checkpoint, pacchetto finale: documento riaperto da Open e Settings contemporaneamente hardware. Runtime/driver/guest restanti invariati. Gli errori effettivamente osservati sono DiscardResource/DiscardView1; la documentazione Microsoft permette al driver di ignorarli, quindi non sono da implementare per tentativi come soluzione dei testi.

Il controllo locale A8_UNORM704×704 conserva contenuto iniziale, due aggiornamenti disgiunti e un ClearView parziale anche su alias di un secondo device. Include attesa esplicita del produttore e opera nello stesso processo: non prova sincronizzazione interprocesso, WDDM o campionamento shader. Fallimento iniziale di compilazione e limiti registrati in VERIFICATION.md. Nessuna serie o matrice aggiunta dopo la riuscita.

Prossima domanda precisa: se la stessa conservazione vale fra processi con sincronizzazione esplicita, poi quale ordinamento/operazione usano realmente Settings/DWM. Non ripetere le copie già verificate, introdurre delta WGC o nuovi boot per questo dubbio. Il difetto WinUI persiste; app e VM sono lasciate sul documento leggibile e hardware, con rollback conservati. Obiettivo affidabilità e fluidità ancora attivo.


### Discrepanza verificata nel completamento GPU —23 ottobre

Completata la domanda precedente: A8 condivisa fra processi distinti e campionamento shader conservano le quattro fasi con attesa esplicita del produttore. Fermare quelle varianti riuscite. Una segnalazione upstream sulle query EVENT ha portato a una differenza concreta nella coppia installata: UMD v0.3 conta Begin, renderer corrente conta End. Il nuovo controllo minimo check-graphics-query-feedback.py riproduce GetData=S_OK/TRUE seguito da DONOTFLUSH=S_FALSE in tutte e tre le fasi. Questo è un difetto di completamento misurato, non ancora la causa dimostrata dei glifi WinUI o di tutti gli scatti.

Prossimo risultato osservabile: una coppia driver/renderer compatibile che completi quel controllo e una breve prova WinUI reale. Il pacchetto ufficiale v0.4 ARM64 è stato scaricato e verificato ma NON installato: REA sul suo DLL conferma Wire2, mentre il runtime ordinario usa Wire1. Prima verificare il comportamento delle query del candidato e individuare il renderer corrispondente; preparare la coppia in una directory privata separata, preservando le patch di durata/ammissione/scanout pertinenti. Prima di una modifica della VM creare un checkpoint offline con arresto ordinario e conservare l'intera coppia precedente. Non promuovere un candidato sulla sola build o sulla creazione del device.

Non reintrodurre il conteggio Begin soltanto nell'host: permetterebbe risultati vecchi delle EVENT riutilizzate. Non esiste nel capset corrente un bit opzionale verificato per disabilitare soltanto questo feedback; l'ipotesi iniziale di un semplice fallback host non è confermata dal protocollo. Evitare altri test A8, matrici di query o correzioni WGC in questo passaggio. Driver/runtime/prodotto correnti, VM sorgente e documento conservati; controllo di qualificazione e prove documentati in VERIFICATION.md. Obiettivo affidabilità/fluidità ancora attivo.


### Candidato v0.4/Wire2 provato e ritirato —23 ottobre

La ripresa precedente è progresso: controllo reale delle query e discrepanza guest/host verificati. Provata ora la coppia v0.4 ARM64 con renderer utmapp/virglrenderer cf5af71359b224a9a482e9b5a67f8160497dc951, quattro commit dopo la base d3c9705. Il DLL firmato invalida la query su End; resta però un'incompatibilità del percorso reale. Due candidati distinti compilati: il primo fallisce il boot grafico, il secondo aggiunge il context_id mancante in RESOURCE_UPDATE ma fallisce ancora con failed to peek24bytes. Né il controllo query né WinUI sono stati raggiunti sul candidato. Non promuovere Wire2 sulla sola versione, build o correzione di una struttura.

Dopo ciascun fallimento, arresto ACPI non completato entro60s; uscita QMP forzata solo del PID/UUID verificato della copia di sviluppo, conservazione offline dello stato fallito e ripristino completo del checkpoint pre-installazione111706Z, compresi disco, UEFI e TPM. Due stati falliti conservati anche nei checkpoint112556Z/113614Z. Non descrivere queste uscite come shutdown ordinari riusciti. Sorgente IoT intatta. Driver e runtime v0.3/Wire1 ripristinati, guardia del frontend ancora limitata aWire1, pacchetto ordinario ricompilato e aperto: documento sintetico ricaricato da Open,51frame hardware e softwareRecovery=false. Dettagli e hash in VERIFICATION.md.

La differenza RESOURCE_UPDATE è confermata sia dal sorgente guest sia dal DLL effettivo: header80byte contro72 della base host; il campo context_id è a offset72. Correzione sperimentale mantenuta soltanto in QA/wire2-pair-20261023/wire2-update-context.patch; non applicarla al vecchio guest Wire1. Non è dimostrata come causa sufficiente del blocco, poiché il secondo boot fallisce ancora. Nessun'altra variante A8 o matrice di query da aggiungere.

Prossimo risultato osservabile: ottenere tipo/dimensione del comando immediatamente precedente alla desincronizzazione e correggere quel confine prima di qualificare la coppia. Preparata e compilata soltanto nel candidato privato wire2-decode-failure.patch: registra stream/byte disponibili e opcode/dimensione dichiarata/consumata del comando precedente solo sul fallimento già fatale, senza payload o puntatori. Non installata. Il build privato ora include quella diagnostica, mentre i due Native3D conservati descrivono i candidati precedenti: rigenerare ricevuta/inventario/hash se si impacchetta il nuovo build. Conservare il runtime ordinario e usare il checkpoint o una copia separata recuperabile; niente terzo boot identico, allargamento del parser o skip di byte per nascondere il guasto. Obiettivo affidabilità/fluidità resta attivo.


### Protocollo esatto e primo controllo GPU riuscito sul clone —23 ottobre

La diagnostica raggiunge la causa successiva: CheckFeatureSupport0xff00571e dichiara48byte, il decoder ne consuma32 e perde il buffer in ingresso. Rigenerazione completa da neptune-protocol f510a6e, esattamente il generatore del peer ufficiale v0.4; tutti311file guest/client/comuni coincidono. Controllo sul codec prima del framing fallisce prima e passa dopo, conservando A8=65. RESOURCE_UPDATE80/context_id resta necessario. Nessuno skip artificiale di byte. Nuovo prepare-native-wire2.py riproduce su copie private con input verificati; patch Wire2 versionata ma non applicata alla coppia ordinaria.

VM isolata TrialMachine e frontend GPU Trial evitano altre installazioni sulla copia ordinaria. Un solo fallimento diagnostico con ACPI non completato e QMP/PID/UUID verificato, stato preservato e ripristino del checkpoint pulito; poi boot20311 collegato e controllo EVENT passato nelle tre fasi. Primo progresso concreto sulla nuova coppia, senza dichiarare risolto l'ordinamento generale. Prova Retina richiede il modo corretto già all'avvio: KMD deduplica connected→connected e2940×1912 non viene riesposto dopo RFB. Nuovo modo iniziale dai pixel Mac già limitati, verificato nel clone e pacchetto ordinario. Non risolve ancora cambio monitor dopo il boot o persistenza DPI; Windows sceglie inizialmente250%.

Clone provato a2940×1912/200% tramite Settings: Display leggibile, HDR conserva etichette mancanti. Documento sintetico/Open hardware e geometria2:1 dopo riconnessione alla stessa VM; il cambio DPI aveva esaurito le riparazioni limitate dell'area utile, senza recupero automatico. Shutdown finale ordinario riuscito/checkpoint122909Z. Clone ora spento, copia ordinaria riaperta col documento hardware. Fonte IoT e driver ordinario v0.3 intatti. Dettagli, fallimenti e hash in VERIFICATION.md.

Prossimo passo concreto: qualificare il runtime finale senza diagnostica Native3D-clean-f510 nella stessa VM isolata, dal checkpoint pulito122909Z, con una sola prova query/documento e riconnessione/resize corretti. È già compilato da source riproducibile e firmato, renderer a93c2e5e34a8/server0869b34035ac, ma non avviato. Non tornare al vecchio parser o ripetere A8 e311confronti già passati; non introdurre altri renderer/driver casuali. Il source e la ricetta Meson sono in QA/wire2-pair-20261023/repro-f510-relocated. Il preparatore pubblico prepara soltanto source, non è un builder/installer completo. Conservare QEMU69c236476db8/backend1a704afafdb1, durata/ammissione/scanout e512MiB. Per una futura promozione rendere ripetibile anche il packaging della coppia finale e conservare il checkpoint ordinario114833Z; guardia Swift ancora soloWire1 fino a quel passaggio. WinUI e fluidità generale restano nell'obiettivo attivo.

Prima della chiusura di questo passaggio, anche la VM ordinaria è stata riportata a200% da Settings:192DPI confermati, documento in primo piano. Non ripetuto il boot per misurare la persistenza. Le stringhe CreateForWindow0x80070057 e mancato completamento della geometria sono ancora comparse nel launcher durante il percorso ordinario; conservarle fra i limiti, senza confonderle con il pass delle query nel clone.


### Coppia corretta consegnata nell'app ordinaria —23 ottobre

Il passaggio precedente è progresso, non conclusione dell'obiettivo. Runtime finale senza diagnostica qualificato nel clone: query passa, modo2940×1912/200% mantenuto al boot, documento/Open e resize2030×1258→1015×629punti riusciti, riconnessione hardware alla stessa VM. Clone spento normalmente, checkpoint124112Z. Nuovo package-native-wire2.py confeziona gli esatti output del build verificato e riproduce i binari a93c2e5e34a8/0869b34035ac, preservando QEMU/backend e tutte le patch necessarie. È packaging da input pinned, non un builder universale.

Promozione completata: checkpoint ordinario pre-installazione123701Z, pacchetto/driver firmato v0.4 verificato e installato oem2.inf/exit0, ACPI riuscito e checkpoint post-installazione124322Z. Frontend ammette soltanto la specifica coppia Wire2/f510/cf5 con capacità richieste; runtime ordinario e .build/Native3D ora aggiornati. Boot22340, tutti gli hash dell'immutabile corrispondenti, DLL ARM64 realmente caricato dal guest b62f463ec4e4. Query nelle tre fasi concorda S_OK/TRUE, display2940×1912/192DPI e primaryMatchesHost=true. Documento/Open e Command-A hardware; stato finale85frame e nessun WARP. Bundle frontend b47590c9c093, guest986610dbc6b4 invariato. Dettagli in VERIFICATION.md.

Settings/System→Display→HDR conserva icone/etichette mancanti anche nella coppia corretta, pur in hardware; CreateForWindow0x80070057 è ancora apparso nel launcher. Non attribuire alla correzione query una soluzione WinUI o una riduzione di latenza non misurata. Fonte IoT e documenti intatti; coppia Wire1 conservata con checkpoint pre-installazione123701Z e bundle/runtime nel QA. Per tornare indietro occorre ripristinare insieme disco/UEFI/TPM/driver e runtime: non usare Wire1 sul driver v0.4 appena installato.

Prossimo risultato osservabile: identificare una texture realmente usata per le parti mancanti di Settings e verificare dove il suo aggiornamento/contenuto si perde, con osservazione circoscritta del produttore/backend corrente. Il pass EVENT permette ora di non basarsi sulla discrepanza già corretta; non prova tutto l'ordinamento GPU. Niente nuova matrice A8/query, riavvii di qualificazione o altro aumento memoria. Conservare il percorso utilizzabile e distinguere sempre dati ricevuti, composizione e presentazione. Affidabilità e fluidità generale restano l'obiettivo attivo.

### Texture reali del produttore osservate —23 ottobre

Cattura Metal limitata al worker Settings/context57 del clone, sulla coppia v0.4 qualificata. Prima prova diagnostica fallita: il bridge startCapture chiamava Metal senza assegnare il risultato, perciò il falso risultato locale saltava lo stop. Arresto ACPI ordinario riuscito; trace incompleto conservato, non qualificato come cattura delimitata. Corretti sia il risultato del bridge sia lo stop indipendente da quel risultato. Seconda cattura conclusa automaticamente dopo quattro gruppi del backend: cinque command buffer Metal con l'inizializzatore, un frame/176draw, clone poi spento normalmente. Patch opzionale native-bounded-capture.patch versionata, non installata nel runtime normale.

Il buffer della texture A8 reale1984×1728 contiene le etichette mancanti dalla finestra (Bluetooth&devices, Network, Accounts e altre). Gli snapshot del vecchio atlas sono identici byte per byte nei due avvii. La nuova A8 2016×2528 contiene prevalentemente Find a setting/controlli: non dedurre da questo una perdita, perché i render pass usano entrambe le texture come target distinti. Xcode conferma Load/Store su entrambe e, nel draw1008, A8Unorm/WriteMaskAll/blending con alpha; la nuova texture mostra effettivamente Find a setting. Quindi non è dimostrato un difetto generale di rendering A8, né che il produttore abbia perso quei testi. Il trace non include ancora il consumer che compone la finestra finale.

Runtime diagnostico e variabili di cattura rimossi dal clone; coppia ordinaria/frontend invariati, documento sintetico riaperto in hardware, geometria Retina2:1 e primaryMatchesHost=true. Dettagli/hash/fallimenti in VERIFICATION.md. Prossimo risultato osservabile: seguire **lo stesso atlas già popolato** nel consumer/compositore, verificando vista, contenuto e ordinamento del suo uso prima di cambiare il driver. Riutilizzare il trace offline finché risponde alla domanda; una futura cattura deve selezionare il contesto consumer con un'evidenza concreta, non tutti i worker. Non ripetere test A8 locali, nuovi driver o boot del produttore già osservato. WinUI e fluidità generale restano obiettivi aperti.

### Il consumer conserva i testi; desktop e finestra divergono —23 ottobre

Il log del produttore collega gli atlas al consumer/context7 tramite export, attach e OpenSharedResource. Due catture circoscritte di quel solo worker nel clone, stesso backend diagnostico58e8634c3858. La prima termina prima del nuovo atlas/Display: conferma importazione byte-identica dell'atlas, ma non osserva il difetto. Non presentarla come cattura della transizione. Nella seconda, armata soltanto dopo screenshot Display con sidebar mancante e42frame hardware, entrambe le A8 contengono ancora i testi corretti nel consumer. Stop automatico riuscito; entrambi gli arresti ACPI riusciti, nessuna uscita forzata. Runtime/frontend privati poi ripristinati, nessuna modifica del driver o della coppia ordinaria.

Nel replay offline della seconda cattura, MTLTexture1 del desktop mostra le etichette, mentre MTLTexture5 BGRA2330×1468 della finestra ha la sidebar mancante come nell'app. Draw46/desktop dichiara gli atlas4/6; draw593/finestra dichiara anch'esso entrambi, con pipeline1 identica. Draw549 usa la nuova A8 per il contenuto Display. I passaggi esaminati conservano Load/Store. La tabella Memory dice None/Never anche per texture poi dichiarate nei disegni: non usarla da sola per dedurre mancato uso delle risorse indirette. Non è ancora provato quale disegno avrebbe dovuto conservare o ridisegnare la sidebar, né che il desktop vivo fosse corretto prima del replay. Dettagli e limiti in VERIFICATION.md.

Prossimo risultato osservabile: dal trace già disponibile identificare i passaggi che scrivono la superficie della singola finestra e confrontarne geometria, clip e contenuto precedente con quelli del desktop. Il contenuto è già errato al momento della seconda cattura, quindi un eventuale bisogno di osservare la prima perdita va motivato da questo limite: nessun altro boot identico o cattura generica del produttore. Non attribuire il problema a FD/A8 assenti, né introdurre full redraw o copie del desktop come riparazione dei pixel. Conservare documenti e percorso hardware utilizzabile. Obiettivo generale ancora attivo.

### Dialoghi: distinguere ammissione, primo frame e contenuto —23 ottobre

L'ispezione offline aggiuntiva del consumer trova copie di tile della pagina destra e un target finestra già incompleto, senza individuare la prima perdita. Nessuna patch a ClearView, scissor o completamento GPU giustificata. Una nuova prova reale di Notepad separa inoltre tre risultati: l'ammissione temporanea del dialogo riesce e ripristina lo stile; una Save As dopo riconnessione rimane a zero callback; una sessione diagnostica nuova sullo stesso HWND riceve un frame ma con gran parte dell'immagine trasparente. Un semplice retry non è quindi una correzione qualificata. Anche mantenere il bit di ammissione per12s su una sessione già avviata non migliora quel caso; non equivale a provare il bit mantenuto durante StartCapture. Quest'ultima variante resta privata e non eseguita.

Fermare qui le varianti del probe: il primo eseguibile diagnostico è anche terminato con access violation in GraphicsCapture.dll_unloaded; il probe corretto ha limiti di apartment e consumo dell'outbox distinti dal worker reale. Fallimenti e pixel grezzi conservati in QA e descritti in VERIFICATION.md. Nessuna modifica sperimentale trasferita al prodotto. La screenshot composita Mac del dialogo non basta a identificare il contenuto ricevuto: usare i pixel del frame.

Rivalutati gli aggiornamenti upstream: il passaggio DXMT a directx-native cambia ABI e richiede una coppia completa; il diff non dimostra una correzione di questo difetto. IncludeSecondaryWindows riguarda soltanto determinate finestre secondarie, senza prova di pertinenza alla sidebar WinUI. Conservare Wire2 qualificato, senza upgrade parziale, nuovi boot o altre matrici A8. Prossimo passo più piccolo: confrontare il contenuto della superficie della finestra prima del readback con i pixel effettivamente ricevuti nella stessa prova, distinguendo alpha e aggiornamenti parziali. Serve un risultato visibile completo prima di introdurre recuperi automatici.

CD diagnostico rimosso, frontend riaperto normalmente, solo il documento sintetico originale lasciato aperto. Primo frame bianco dopo riconnessione, poi contenuto leggibile dopo attivazione e selezione, senza modifiche salvate; hardware e geometria confermati. Registrare questa dipendenza dall'attivazione come limite, non come riconnessione trasparente risolta. VM e binari ordinari conservati. Affidabilità e fluidità restano l'obiettivo attivo.


### Recupero del primo frame vuoto della finestra principale —23 ottobre

Dal PNG ricevuto nel passaggio precedente emerge un caso più piccolo e correggibile: anche il documento principale riconnesso può ricevere un primo frame interamente BGRA0 e attendere un input prima di ridisegnarsi. Esteso il recupero già presente nei dialoghi alla prima immagine interamente vuota del main. Una sola RedrawWindow asincrona sullo stesso HWND autenticato e visibile; per il frame completo include anche l'area nonclient. Stato della richiesta nel nuovo guestInitialFrameRepaint, vecchio campo dei dialoghi preservato. Nessuna sessione/device aggiuntiva.

Build, installer ordinario e pacchetto finale verificati, senza reboot o cambio driver/runtime GPU. Le prime due riconnessioni ricevono direttamente contenuto e non qualificano il ramo nuovo. Il caso mirato Open→riconnessione→Escape lo esercita: main differito durante il modale, poi frame1 interamentezero con richiesta true, frame2 e3 con documento/titolo/controlli completi, senza input di recupero fra i frame. Dettagli e PNG grezzi in VERIFICATION.md. La riapertura normale finale mostra il documento leggibile e hardware, dati intatti. Sorgente ed evidenze fanno parte dello stesso incremento verificato.

Questo è un miglioramento circoscritto della riconnessione, non una soluzione dei frame WinUI parziali o una misura di fluidità. Il prossimo intervento rimane sul contenuto della superficie finestra prima del readback rispetto ai pixel ricevuti nella stessa prova. Non ripetere il caso modale appena riuscito o altre varianti del probe privato. Obiettivo generale ancora attivo.


### Preparatore ordinario allineato alla coppia Wire2 —23 ottobre

La ripresa del confine grafico ha individuato un'incoerenza nel prodotto: il runtime promosso usa Wire2/v0.4, ma guest/graphics-driver.json e le istruzioni del preparatore indicavano ancora v0.3. Corretto il manifest ordinario agli undici membri del pacchetto ARM64x firmato v0.4 già qualificato, verificati contro archivio e digest ufficiale. Il preparatore controlla prima la corrispondenza Wire2/cf5/f510 nel runtime dell'app finale; il vecchio payload o un'app Wire1 vengono rifiutati prima di creare media. Aggiunto --dry-run per verificare gli input senza modificare il CD della VM.

Verifiche mirate riuscite: preparazione senza modifiche con la coppia corretta, rifiuto del vecchio payload, rifiuto di un manifest Wire1 in fixture privata, CD reale letto dal guest con undici hash e catalogo Valid. DLL staged identico a quello già installato b62f463ec4e4. Nessuna reinstallazione del driver o reboot: la qualificazione precedente rimane la prova del suo funzionamento; questo passaggio verifica il percorso di preparazione corretto. Due errori nelle asserzioni locali di verifica sono descritti in VERIFICATION.md. CD rimosso, documento e cattura hardware conservati.

Questo evita di ricreare una coppia incompatibile con la preparazione ordinaria, senza attribuire una soluzione WinUI al cambio del manifest. L'indagine sulla superficie per finestra rimane aperta; non ripetere installazione v0.4, boot o query già qualificati. Obiettivo affidabilità/fluidità ancora attivo.


### Staging busy escluso e un invio in meno nel readback —23 ottobre

REA sul DLL v0.4 installato b62f463ec4e4 conferma che ResourceIsStagingBusy è già una funzione che restituisce0: non esegue il Map/Unmap ipotizzato nella vecchia segnalazione. Ipotesi esclusa per questo callback. Il percorso Flush11.1 ignora invece FlushFlags e restituisce1 dopo il Flush host per un device valido; non è provato che produca il difetto WinUI. Nessuna modifica binaria, test signing o nuovo driver. Evidenze statiche e limiti in VERIFICATION.md; sessione REA chiusa.

Sul nostro readback, la rimozione completa dei Flush per fascia mantiene i pixel leggibili ma non migliora i due campioni: scartata. Scelto un passo più piccolo che mantiene la pipeline: inviare insieme le prime due copie, poi Flush immediato dopo ogni riuso di uno staging. Nel documento2352×1480,2slot/7fasce, questo porta i Flush espliciti da7a6, con budget, Map bloccante e copie invariati. Superfici a un solo slot seguono lo stesso invio precedente.

Guest finale98ba16512695 installato nel pacchetto reale; due aggiornamenti senza modificare il testo, riconnessione e PNG grezzi verificati. Tutti i pixel RGB sotto il titolo coincidono con il riferimento, nessun WARP o arresto cattura. Tempi prima8,39/23,18ms, finale15,98/21,28ms: variabilità troppo grande per dichiarare fluidità o latenza migliorate. Risultato circoscritto: un invio esplicito ridondante rimosso, contenuto conservato. Fermare qui queste varianti, senza ampliare il benchmark. App normale e documento intatto, CD rimosso, stessa VM senza reboot.

WinUI parziale e sessioni senza primo callback restano aperti. Tornare alla prima costruzione/conservazione della superficie per finestra: i trace precedenti osservano o lo stato prima della transizione o un output già incompleto, non la prima perdita. Non ripetere A8/query, patch a ResourceIsStagingBusy già corretto o nuove varianti del readback per attribuire una causa non dimostrata. Obiettivo affidabilità/fluidità ancora attivo.


### Installazione Wire2/v0.4 sul Mac locale

Richiesta dell'utente: installare e verificare la coppia sul Mac locale, rimandando la discussione dei prossimi passi. I binari privati dell'altra macchina non erano disponibili. Ricostruito il renderer cf5/f510 a partire dal profilo window-recovery locale con inventario esplicito, protocollo peer verificato e patch correnti; conservati QEMU/backend locali. È una build distinta dalla precedente qualifica IoT. Driver firmato v0.4 installato, nuovo guest collegato e moduli effettivi nel worker verificati contro gli hash della release. Dettagli e ricetta in VERIFICATION.md e graphics/renderer/README.md.

Controllo EVENT passato, Blocco note hardware leggibile con input, recupero dello stesso testo dopo riconnessione e resize Retina2:1. Area utile allineata soltanto dopo la riapertura del frontend; un dialogo intermedio apparso vuoto rimane un limite. Arresto iniziale dopo il cambio driver non completato né via ACPI né via comando Windows: uscita QMP autenticata necessaria, checkpoint offline precedente e stato post-installazione conservati. App lasciata aperta; nessuna affidabilità generale o soluzione WinUI dichiarata, nessuna ulteriore indagine iniziata.


### Resize con anteprima locale — richiesta aggiornata del 23 ottobre

L’utente ha respinto le prove di resize continuo: miglioramento iniziale del gesto, seguito da spostamenti, sparizioni e grandi aree trasparenti; anche gli aggiustamenti di ancoraggio/cattura non hanno prodotto un risultato accettabile. Abbandonare questa direzione. Richiesta sostitutiva: durante il trascinamento mostrare soltanto una selezione rettangolare Mac elegante, con bordo sottile e riempimento tenue; conservare dimensioni, posizione e immagine della finestra originale. Inviare un solo resize a Windows al mouse up e applicare il nuovo contenuto insieme alla geometria confermata quando il frame è disponibile.

Rimosse le modifiche sperimentali a scala, renderer e cattura guest. Il movimento ordinario conserva il proprio comportamento. Questa scelta evita di ripetere le varianti realtime fallite; non attribuisce una soluzione generale dei difetti WinUI al nuovo gesto. Evidenze puntuali e limiti in VERIFICATION.md.


### Area utile del Mac e minimi per finestra —23 ottobre

Nuova richiesta: all’avvio dimensionare il monitor virtuale sull’area massima disponibile alle normali finestre Mac, considerando barra dei menu, Dock e sua scomparsa automatica. Usare la risoluzione Retina corrispondente e collocare l’origine guest nell’origine di questa area utile. Windows conserva la gestione della propria taskbar all’interno del monitor: non sovrascriverne la work area per simulare una seconda riserva Mac. Il monitor primario resta il percorso qualificato; gli altri monitor sono inventariati ma non aggiunti automaticamente al guest.

Comunicare inoltre il minimo della singola finestra Windows al contenitore Mac, applicandolo al gesto e all’anteprima prima dell’invio finale. Distinguere un limite risposto dall’app da quello prudenziale usato se non risponde. Richiesta aggiuntiva esplicita dell’utente durante le prove: le modifiche non salvate delle app dentro questa VM di test sono sacrificabili; non chiedere nuovamente di salvarle prima dei riavvii o della chiusura necessari alle prove. Questo non autorizza cancellazioni di dischi, credenziali o dati esterni alla sessione di test.


### Copertura delle transizioni e cursori resize —23 ottobre

Richiesta corrente: coprire gli aggiornamenti visivamente incompleti durante avvio delle app, cambio risoluzione e operazioni che richiedono un nuovo frame. UI Mac con materiale sfocato, icona reale dell’app e indicatore ad anello ispirato a Windows11, rimossa quando il presenter ha mostrato il frame necessario. Non introdurre un ritardo fisso o scambiare la ricezione del pacchetto per presentazione. L’attesa prolungata deve avere un esito esplicito e accesso al desktop Windows. Conservare l’anteprima di sole dimensioni durante il drag; la copertura del resize inizia al rilascio. Aggiungere cursori Mac sui bordi e sugli angoli delle finestre principali, coerenti con le regioni effettivamente ridimensionabili.

Il mascheramento non costituisce una correzione del rendering WinUI. Le verifiche di avvio, resize normale e ritardo simulato sono riportate in VERIFICATION.md. Nessun cambio guest/driver o ampliamento delle prove GPU richiesto da questa UI.


### Dimensione Mac immediata al rilascio —23 ottobre

Richiesta successiva dell’utente: invertire il verso dello spinner e, al mouse up, portare subito la finestra Mac alla geometria scelta, mostrando icona e spinner nella nuova area fino al frame Windows. Questo aggiorna la precedente attesa alla vecchia dimensione. Durante il trascinamento resta soltanto il rettangolo di anteprima. Conservare conferma della geometria, filtro dei frame e presentazione effettiva prima di scoprire il contenuto; nessun invio intermedio di resize.


### Ripresa grafica e drawable Metal temporaneamente assente —23 ottobre

Richiesta rinnovata: migliorare driver, accelerazione3D e presentazione dei frame su Mac, ancora instabili. Obiettivo attivo registrato anche nella chat. REA su Parallels e debug GPU Xcode sono strumenti autorizzati quando rispondono a una domanda concreta; le catture Xcode precedenti rimangono evidenza circoscritta, non una soluzione dimostrata.

Primo incremento sul presenter: quando nextDrawable restituisce nil senza un frame successivo, il codice precedente lasciava l'immagine statica in attesa indefinita. Ora riprova la sola acquisizione dello stesso contenuto al massimo tre volte, con attese50/100/200ms dopo il fallimento; poi segnala un errore. clear cancella il tentativo pendente. Non richiede repaint, altra cattura o copie di pixel Windows. Controllo con nil indotto su copie private, GPU/presentazione reali: prima nessun completamento, dopo presentazione senza nuovo frame; indisponibilità persistente produce errore e clear cancella il retry. Il tentativo preliminare di esaurire il pool reale non ha riprodotto nil ed è stato scartato. Nessuna frequenza reale di questo guasto è stata misurata.

Pacchetto finale compilato e verificato con Blocco note classico hardware: avvio, input e resize2378×1400→2178×1300 completi. Riconnessione eseguita con un dialogo guest incompleto già presente: main inizialmente differito, recuperato dopo Mostra comunque/Escape sul dialogo. Non qualificare questo come riconnessione trasparente o soluzione dei dialoghi. Nessun cambio driver/guest/runtime né reboot. Dettagli e fallimenti in VERIFICATION.md.

WinUI parziale, sessioni senza callback e affidabilità generale restano aperti. Il prossimo intervento grafico sostanziale rimane confrontare la superficie per finestra prima del readback con i pixel ricevuti nella stessa transizione che perde contenuto, usando una cattura GPU delimitata solo se necessaria. Non ripetere A8/query/readback o boot già esclusi; non attribuire questo recupero del drawable ai difetti del rendering guest.
