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
- Il ridimensionamento tramite trascinamento non è stato confermato dall'automazione Mac. Il collegamento alla richiesta Windows è implementato, ma resta da riverificare nell'uso manuale; il limite del desktop guest RAMFB iniziale è 800×600 e può incidere sull'input fuori schermo.
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
