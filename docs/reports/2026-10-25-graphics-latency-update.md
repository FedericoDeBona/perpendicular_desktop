# Aggiornamento pratico: attesa dell’immagine e UI Mac

25 ottobre2026 · versione installata0.2.4.

## Cosa cambia per l’utente

**Ho ridotto il lavoro inutile della UI Mac e installato questa modifica. Non ho ottenuto una riduzione verificata dell’attesa di presentazione.** Le varianti provate per quel punto sono state escluse perché peggioravano gli scarti o non davano un beneficio utilizzabile.

La0.2.4 consegna i frame direttamente alla coda dell’interfaccia, mantenendo un solo aggiornamento pendente per finestra. Inoltre evita di notificare di nuovo al launcher stati identici di app e VM. Per la memoria controlla i valori che il pannello mostra: un nuovo timestamp diagnostico, da solo, non fa più aggiornare tutta l’interfaccia. Il controller RAM continua a funzionare come prima.

La verifica nella build finale ha registrato70 risposte app invariate e33 controlli memoria senza cambiamenti visibili per cui la pubblicazione è stata saltata. È una riduzione concreta di lavoro evitabile; **non equivale a103 frame guadagnati o a un numero di millisecondi risparmiati**.

Il ritardo UI occasionale di32 ms del report precedente non è dimostrato risolto. Nel campione finale di33 frame di una nuova finestra Notepad, copia completata→dispatch UI ha mediana0,250 ms e massimo0,752 ms. La scena differisce dal riferimento iniziale: questi numeri qualificano il percorso, non una percentuale di miglioramento.

## Cosa ho provato per mostrare prima l’immagine

Riferimento e varianti di presentazione hanno usato lo stesso documento temporaneo Notepad e otto coppie Pagina giù/Pagina su, con verifica UI fra i tasti. Il desktop era1920×1280; la finestra individuale1422×860. Le finestre temporali sono delimitate dalle azioni, non dall’intera sessione del frontend. Gli scarti restano nel conteggio.

| Prova | Presentazioni con timestamp positivo / comandi | Mediana ingresso frontend→presentazione | Esito |
| --- | ---: | ---: | --- |
| Riferimento, finestra individuale | 35/38 | 33,912 ms | Riferimento;3 timestamp zero. |
| Riferimento, desktop | 33/41 | 27,925 ms | Riferimento;8 timestamp zero. |
| Segnale di refresh Metal, finestra individuale | 2/35 | 48,973 ms sui soli2 positivi | Respinta:33 timestamp zero; la mediana non descrive una soluzione valida. |
| Segnale di refresh corretto nella gestione della pausa, desktop | 3/28 | 55,497 ms sui soli3 positivi | Respinta:25 timestamp zero. |
| Presentazione coordinata alla transazione UI, desktop | 40/48 | 31,245 ms | Beneficio non dimostrato; finestra individuale inizialmente bianca. Respinta. |

Tutti i command buffer conteggiati in queste righe sono completati senza errore GPU. Questo **non basta** per chiamare mostrata un’immagine: è il motivo per cui ho controllato anche il timestamp di presentazione e il primo frame visibile.

Sono state usate le API documentate [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink), con latenza richiesta di un frame, e [presentsWithTransaction](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction). I risultati riguardano queste implementazioni a richiesta, non dimostrano che le API siano generalmente inutilizzabili. La versione finale mantiene il presenter precedente: due drawable, sincronizzazione verticale attiva, copia/ownership e ACK invariati. Nessuna modalità sperimentale viene distribuita.

## Verifica della versione mantenuta e limiti

Nella build finale: nuova apertura Notepad, testo, cursore, dialogo Salva/Non salvare e chiusura riusciti; desktop nativo visibile. Il piccolo campione finale dell’app contiene33 immagini ricevute,32 comandi completati,26 presentazioni positive e6 timestamp zero, senza errore command buffer. Una sorgente è sostituita prima della selezione. È una scena diversa dal riferimento di scorrimento; non ne deduco un A/B favorevole.

Nell’app ordinaria0.2.4 sono stati verificati di nuovo Notepad con testo visibile, cursore, dialogo di chiusura e desktop nativo. Campionamento del frontend per5 s: il thread principale risulta prevalentemente in attesa nel run loop; non ha identificato la causa dell’episodio precedente da32 ms. Non è una prova che quel ritardo non possa ricomparire.

Durante alcune riconnessioni del vecchio documento sono ricomparsi errori di corrispondenza fra pixel guest e copia host, prima del presenter. Conservati come esiti negativi di GFX-003; controlli e hash non aggirati. Una nuova finestra ha permesso la verifica finale, senza qualificare il recupero dello stesso documento. Nessuna attribuzione causale automatica a Wait/Signal o alla nuova coda UI. La preparazione iniziale di molto testo tramite automazione ha inoltre prodotto righe/lettere irregolari già nel desktop: il documento era solo materiale di prova, non una qualifica dell’inserimento di testo lungo.

## Stato lasciato

App0.2.4 installata e verificata, copia completa della precedente0.2.3 conservata in Research. Windows continua nello stesso boot e processo QEMU, con configurazione CPU/RAM invariata. Secure Boot e Code Integrity attivi, modalità test disattivata. Documenti di prova chiusi senza salvataggio, nessun documento utente modificato.

**Punto1:** nessuna soluzione promossa, attività aperta. **Punto2:** correzione del lavoro ripetuto implementata e verificata nella build e nell’app ordinaria; riduzione del ritardo occasionale non ancora dimostrata. TODO-004/007 restano IN CORSO. Il successivo intervento sul ritardo UI richiede riprodurre un evento lento con attribuzione dello stack, non altri confronti di pacing alla cieca.

[Evidenze e fallimenti](../VERIFICATION.md#25-ottobre--tentativi-di-riduzione-latenza-e-ui-024). Tracce, screenshot, parser e candidate escluse sono conservati privatamente in `Perpendicular Research/Graphics-Latency-20261025`, fuori Git. [Report di analisi iniziale](2026-10-25-graphics-pipeline.md).
