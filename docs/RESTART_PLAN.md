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
