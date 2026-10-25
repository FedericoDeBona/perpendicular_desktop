# Apertura di Esplora file nel desktop della VM

Rapporto del **25 ottobre 2026**. App ordinaria **Perpendicular 0.2.3**, sorgenti di riferimento `fb73fb9`. Richiesta: misurare l’apertura di Explorer dentro Windows, fino al contenuto visivo completo, senza usare le finestre delle app integrate nel Mac; consegnare una diagnosi con possibili colli di bottiglia prima di intervenire.

**Risultato principale.** Il comportamento segnalato è riprodotto: l’esistenza della finestra anticipa di diversi secondi il contenuto completo. Nella prova Home con osservazione leggera, la finestra è rilevata a **1,39 s**, mentre il primo frame vicino al riferimento completo è acquisito entro **5,41 s**. Compaiono prima una superficie bianca e poi parti della UI. Una seconda Home con campionamento CPU host arriva al riferimento completo entro **11,06 s**. Anche Questo PC mostra il problema: primo frame completo entro **9,71 s**, poi una nuova fase con indicatore di caricamento, conclusa visivamente intorno a **13,20 s**.

Questi tre tempi descrivono **tre condizioni diverse**, non una distribuzione statistica del normale tempo di apertura. Non sono una media, un percentile o un confronto controllato fra Home e Questo PC. La prova con profiler costa risorse; la pressione di memoria cambia; Questo PC viene gestito da un nuovo processo Explorer.

Le evidenze indirizzano prima verso **pressione di memoria dell’host, lavoro del guest e costruzione progressiva della UI**. Non emerge una coda Mac che trattiene per tutti quei secondi un unico frame già completo: durante l’attesa continuano pubblicazioni e ACK del desktop. Restano possibili contributi del driver e della traduzione grafica; i dati non permettono di assegnare loro una durata esatta o una responsabilità esclusiva.

**1. Sistema e condizioni effettive**

| Elemento | Condizione osservata |
| --- | --- |
| Mac | Apple M1, 8 CPU logiche, **8 GiB** di RAM; macOS 27.2, build 26B118. |
| App | `/Applications/Perpendicular.app`, 0.2.3; frontend `f3c1b8d064e4`. |
| Windows | IoT Enterprise LTSC ARM64, build 26100; boot della sessione alle **17:20:44, ora di Roma**. |
| Protezioni | Secure Boot **attivo**, Code Integrity **attiva**, opzioni CI 49157, TESTSIGNING **falso**, verificati nella sessione analizzata. |
| Risorse impostate | 4 vCPU, RAM iniziale **1024 MiB**, capacità hotplug **3072 MiB**, massimo totale **4096 MiB**. |
| Gestione RAM | Controller automatico ordinario attivo; minimo corrente 1536 MiB, riserva 512 MiB. Non congelato per le prove. |
| Percorso grafico | Desktop Native3D attivo, scanout **2560×1080**, vista Mac 960×640 punti, scala 2. Presentazione con letterboxing. |
| Percorso delle app integrate | Non usato: nessun avvio di Explorer dal catalogo Mac, nessuna finestra individuale integrata durante la raccolta. |
| Stato del prodotto | Nessun aggiornamento dell’app, del renderer o dei driver; nessun riavvio Windows e nessuna modifica delle impostazioni di Explorer per questa analisi. |

La VM è stata riaperta all’inizio della sessione di lavoro. Prima delle aperture misurate erano già disponibili desktop, collegamento guest e RAM aggiunta automaticamente. Non si sta cronometrando un intero avvio di Windows con solo 1 GB disponibile. Nelle prove B–D Windows riporta circa 3994–4012 MiB di memoria fisica totale; questo dato comprende memoria eventualmente occupata dal balloon e **non equivale alla RAM effettivamente utilizzabile dalle app**.

Le altre applicazioni del Mac sono rimaste nelle condizioni ordinarie. Non sono state chiuse per costruire artificialmente un ambiente scarico. Questo rende il rapporto pertinente al sistema osservato, ma impedisce di trattarlo come benchmark isolato dell’hardware o del solo Explorer.

**2. Cosa significa “apertura” in questo rapporto**

Il punto iniziale **T0** è letto nel guest immediatamente prima di `Process.Start("explorer.exe", ...)`, con `UseShellExecute=true`. Per Home non vengono passati argomenti; per il controllo Questo PC viene passato `shell:MyComputerFolder`.

Il comando viene preparato attraverso il guest tool, senza chiedere al launcher Mac di creare una finestra integrata. La preparazione del processo diagnostico e la sincronizzazione degli orologi precedono T0. Il loro tempo non viene confuso con quello di Explorer. Non è invece misurato il tratto **click fisico → input RFB → ricezione Windows**: questa prova usa un comando guest, non un click sulla taskbar.

Sono separati i seguenti traguardi:

| Traguardo | Cosa dimostra | Cosa non dimostra |
| --- | --- | --- |
| Ritorno della chiamata di lancio | Il percorso di richiesta dell’apertura è tornato al chiamante. | Finestra, contenuto o rendering pronti. |
| Nuova finestra visibile rilevata da Windows | Una nuova `CabinetWClass` è visibile alle API Win32. | Primo paint completo, presentazione DWM o visualizzazione sul Mac. |
| Superficie bianca nel desktop acquisito | È arrivata una prima porzione visibile della nuova finestra. | Contenuto della cartella disponibile. |
| Barra laterale completa | Navigazione laterale leggibile e vicina al riferimento finale. | Barra dei comandi, scheda o contenuto centrale completi. |
| Contenuto centrale completo | Icone, nomi e messaggi attesi presenti nella regione centrale. | Fine di ogni lavoro in background o assenza di ulteriori refresh. |
| Primo frame complessivamente conforme | Barra superiore, sidebar, corpo e contatore vicini al riferimento finale. | Interattività verificata con un click, misura dei fotoni del display o quiescenza permanente. |
| Stabilizzazione finale osservata | Le regioni considerate restano conformi fino alla fine della registrazione. | Affidabilità nel tempo, fuori da quei pochi secondi. |

Per Home il riferimento contiene sei cartelle Quick access con icone e nomi, Favorites/Recent con i messaggi vuoti, navigazione, scheda, indirizzo, ricerca, comandi e contatore. Per Questo PC contiene le due unità, il relativo testo e gli stessi elementi generali della finestra.

La conformità è stata cercata confrontando quattro regioni dei frame con il riferimento finale: barra superiore, sidebar, corpo, contatore. La soglia usata ammette meno dello 0,1% di pixel con differenza superiore a 12 livelli di colore per regione. Le sequenze e i frame di confine sono stati anche ispezionati visivamente.

**È una misura conservativa della convergenza visiva**, non l’istante esatto in cui l’ultimo glifo diventa riconoscibile. Alcuni frame immediatamente precedenti sono già quasi completi; differenze di opacità, animazione o pochi pixel possono ritardare il superamento della soglia. I numeri utili sono quindi in decimi di secondo, non nei millisecondi decimali del file grezzo.

**3. Sequenze misurate**

| Prova | Ora di Roma di T0 | Modalità | Ritorno lancio | Finestra rilevata Windows | Prima superficie bianca acquisita | Sidebar conforme | Barra superiore conforme | Corpo conforme | Primo frame complessivamente conforme |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| B | 17:30:36 | Home, osservazione leggera | 0,291 s | 1,392 s | entro 1,737 s | entro 2,996 s | entro 5,137 s | entro 5,411 s | **entro 5,411 s** |
| C | 17:36:42 | Home, con Time Profiler su QEMU | 1,096 s | 3,246 s | entro 3,875 s | entro 6,690 s | entro 10,817 s | entro 11,062 s | **entro 11,062 s** |
| D | 17:38:30 | Questo PC, osservazione leggera | 0,360 s | 3,634 s | entro 3,887 s | entro 6,937 s | entro 9,712 s | entro 8,933 s | **entro 9,712 s** |

I tempi “entro” sono limiti superiori dati dall’acquisizione del frame. Le catture che per prime superano la soglia complessiva occupano gli intervalli **5,338–5,411 s**, **10,977–11,062 s** e **9,623–9,712 s**. Non è corretto interpretarli come limiti inferiori dell’esistenza del contenuto, perché il criterio include la vicinanza all’aspetto finale.

Il divario fra rilevazione della finestra e acquisizione conforme è di circa **4,02 s in B**, **7,82 s in C**, **6,08 s in D**. È il tratto più direttamente collegato alla segnalazione dell’utente. È un divario fra due osservazioni, non una misura isolata del trasporto GPU.

In B il contatore è già conforme intorno a **4,22 s**, circa 1,19 s prima della convergenza del corpo. In C lo è intorno a **7,07 s**, quasi quattro secondi prima del corpo. **Un contatore o una finestra già presenti non sono quindi un criterio valido di “frame pronto”.**

In D, dopo la prima conformità a 9,71 s, compare nuovamente l’indicatore di caricamento nella scheda e il comando di arresto caricamento. Il corpo con le due unità rimane presente. Le modifiche interessano la barra superiore, non un ritorno del corpo a una pagina bianca. La convergenza finale osservata ricomincia entro **13,20 s** e prosegue fino alla fine delle acquisizioni, circa 13,8 s da T0. Questo secondo tratto va distinto dal primo caricamento dei contenuti.

B e C riusano il processo Explorer che gestisce la shell del desktop. D apre un nuovo processo, ancora vivo e proprietario della stessa finestra in una verifica successiva. Questo rende D utile a dimostrare che il fenomeno esiste anche in Questo PC, ma **non** un confronto causale pulito del costo delle due destinazioni.

Non sono stati calcolati media, p95 o p99: tre casi diversi non sostengono quelle statistiche. Cache del sistema operativo e del driver non sono state svuotate, e non è stato riavviato il guest per ottenere una “cold run”.

**4. CPU: lavoro effettivo e attribuzione possibile**

| Misura nel processo proprietario della finestra | B — Home | C — Home con profiler | D — Questo PC |
| --- | ---: | ---: | ---: |
| Processo già esistente prima dell’apertura | Sì | Sì | No |
| Incremento CPU Explorer osservato | **5,266 CPU-s** | **6,313 CPU-s** | **5,625 CPU-s** |
| Ultimo campione guest rispetto a T0 | 8,804 s | 8,463 s | 8,983 s |
| Page fault del processo, incremento | 18.432 | 13.249 | 43.854 dalla nascita del nuovo processo |
| Letture esplicite contabilizzate al processo | 55.582 byte | 52.275 byte | 49.375 byte |

CPU-s indica tempo CPU cumulato sui thread, non tempo trascorso. Il lavoro di Explorer è significativo in tutti e tre i casi. In B la maggior parte della crescita CPU è già avvenuta quando il contenuto converge. In C il campionamento guest termina **prima** degli 11,06 s del frame conforme: 6,313 CPU-s è il lavoro osservato fino a quel momento, non il costo totale dell’intera apertura. Lo stesso limite vale per gli ultimi refresh di D.

Il basso numero di byte letti esplicitamente da Explorer non dimostra assenza di I/O: caricamenti di immagini, paging, file mappati e altri processi non sono rappresentati integralmente da quel contatore. I page fault non distinguono qui fault soft e letture effettive dal disco; non vengono chiamati impropriamente “hard fault”. [Definizione Microsoft di PROCESS_MEMORY_COUNTERS](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters).

Il costo host è stato letto con `proc_pid_rusage`, confrontando campioni vicini a T0 e al primo frame complessivamente conforme:

| Processo/gruppo host | B, finestra osservata ≈5,47 s | C, ≈11,20 s | D, ≈9,78 s |
| --- | ---: | ---: | ---: |
| QEMU, CPU cumulata | **12,112 CPU-s** | **23,042 CPU-s** | **23,036 CPU-s** |
| QEMU, core medi equivalenti | 2,21 | 2,06 | 2,36 |
| Frontend Swift, CPU cumulata | 0,672 CPU-s | 1,158 CPU-s | 1,176 CPU-s |
| Renderer/server presenti all’inizio, CPU cumulata | 0,735 CPU-s | 0,983 CPU-s | 0,821 CPU-s |

Sono finestre di campionamento con estremi non perfettamente coincidenti ai milestone, non misure nanosecondo per nanosecondo dell’apertura. Il gruppo renderer contiene i processi presenti prima del lancio; eventuali nuovi worker non sono inclusi retroattivamente. Il suo valore è quindi una copertura parziale, soprattutto per D, che crea un nuovo processo guest.

Su questo M1 i contatori CPU grezzi sono stati convertiti dal timebase Mach **125/3 ns per tick**, verificando la coerenza con il tempo CPU mostrato da `ps`. Trattarli direttamente come nanosecondi avrebbe sottostimato i costi di circa 41,7 volte. L’analisi finale applica la conversione; i file grezzi mantengono i valori originari. Il [codice XNU relativo al popolamento di rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) distingue queste grandezze da memoria residente e footprint.

Il tempo CPU guest è **contenuto nel lavoro eseguito tramite QEMU/HVF**: non si sommano 5,3 CPU-s di Explorer e 12,1 CPU-s di QEMU come costi indipendenti. QEMU comprende inoltre gli altri thread Windows, dispositivi virtuali, I/O e gestione dell’hypervisor. Il valore non è il costo esclusivo di Explorer.

Time Profiler ha prodotto una traccia valida del processo QEMU per C. Sull’intera registrazione, non sulla sola apertura, ci sono 32.074 campioni con peso nominale di 1 ms:

| Classificazione dello stack host | Quota dei campioni pesati |
| --- | ---: |
| Confine di esecuzione HVF, stack con `hv_trap` | **86,00%** |
| Altri stack che attraversano `hvf_vcpu_exec` | 7,93% |
| Altri thread/percorsi QEMU | 5,57% |
| Stack non disponibile | 0,50% |

Il peso dei campioni non è una misura del lavoro di una funzione Windows. **86% in `hv_trap` non significa 86% di overhead dell’hypervisor**: il profiler Mac vede il confine dentro cui gira il guest e non può attribuire quel tempo alle funzioni interne di Explorer, DWM o del driver Windows. La traccia non isola quindi layout XAML, enumerazione Shell, shader o paging guest. Sono necessari eventi/stack guest per compiere quel passo.

**5. Memoria: l’indizio più importante da verificare causalmente**

| Contesto guest all’inizio/fine della raccolta dei processi | B | C | D |
| --- | ---: | ---: | ---: |
| Memoria fisica totale riportata | 3993,9 → 3993,9 MiB | 4011,9 → 4011,9 MiB | 4011,9 → 4011,9 MiB |
| Memoria disponibile | **941,5 → 887,5 MiB** | **1270,6 → 1241,5 MiB** | **597,0 → 516,8 MiB** |

Non c’è evidenza che queste aperture stiano aspettando ancora tutto l’hotplug necessario ad arrivare al massimo configurato. C’è però un controller di memoria attivo: balloon e reclaim possono lavorare mentre l’app Mac non risulta in primo piano. In un successivo rilievo ordinario il controller riporta circa 3254 MiB effettivi, balloon 768 MiB e un ulteriore adattamento in corso. **Il totale fisico esposto da Windows, da solo, non descrive questo stato.** Non sono state registrate tutte le variazioni del balloon durante ciascuna apertura: il suo costo specifico rimane da isolare.

Sul Mac l’evidenza è più forte. Le differenze di `vm_stat`, con pagine da 16 KiB, mostrano:

| Traffico di swap dell’intero Mac durante la raccolta, inclusi preparazione e recupero risultati | B | C | D |
| --- | ---: | ---: | ---: |
| Swap-in | **508,8 MiB** | **1933,7 MiB** | **420,0 MiB** |
| Swap-out | **498,1 MiB** | **2186,6 MiB** | **525,6 MiB** |

Queste sono misure **di sistema e di finestre più lunghe della sola apertura**. Includono osservatore, strumenti e altre applicazioni. Non dimostrano che Explorer abbia causato tutto lo swap o che ogni suo secondo di attesa sia swap. Dimostrano però attività di scambio consistente, non soltanto una quantità storica di swap già occupata. La prova C è particolarmente perturbata anche dal profiler.

Un rilievo `vmmap -summary` di QEMU, effettuato successivamente alle aperture alle 17:49 circa, conferma un contesto oneroso: **footprint 7,8 GiB, picco 8,1 GiB**, circa 251 MiB residenti nel riepilogo delle regioni e circa **4,0 GiB riportati come swapped**, di cui circa 3,8 GiB nella categoria shared memory. È una fotografia successiva, non la fotografia dell’istante di apertura di B.

Footprint, RSS, memoria virtuale riservata, pagine compresse e swap sono contabilità differenti. Non è corretto tradurre quel dato in “7,8 GiB di RAM fisica residente per QEMU”, sommarlo ingenuamente alle altre colonne o chiamare i circa 392 GiB di spazio virtuale riservato “RAM occupata”. Non è ancora identificato quanto dipenda dal backing guest, da mapping condivisi/HVF, dalla loro contabilizzazione o da altre risorse del processo. Il contrasto con il massimo di 4 GiB **merita una misura separata**; il limite della RAM Windows non è un limite rigido al footprint Mac.

**Ipotesi sostenuta, non diagnosi conclusa:** l’interazione fra VM, altre app, compressore, swap e gestione automatica può penalizzare molto il tempo di risposta. Prima di aumentare la RAM Windows per rendere Explorer più veloce occorre evitare di peggiorare la pressione sul Mac da 8 GiB. Non è stata modificata la configurazione per verificare questo effetto: manca ancora un confronto con una sola variabile cambiata.

**6. Disco e I/O**

Il nodo del disco di sistema è stato letto con QMP `query-blockstats`, circa ogni 200 ms. La tabella usa le differenze fra i campioni host prossimi a T0 e al primo frame conforme, senza sommare anche i nodi figli e contare due volte lo stesso traffico.

| Nodo disco Windows, finestra dell’apertura osservata | B | C | D |
| --- | ---: | ---: | ---: |
| Letture | **54,8 MiB / 1733 operazioni** | **268,2 MiB / 4980 operazioni** | **190,1 MiB / 6343 operazioni** |
| Tempo di lettura medio per operazione | 0,549 ms | 1,048 ms | 0,425 ms |
| Scritture | 101,9 MiB / 934 operazioni | 99,3 MiB / 1054 operazioni | 89,5 MiB / 3776 operazioni |
| Tempo di scrittura medio per operazione | 0,901 ms | 0,808 ms | 0,275 ms |
| Operazioni di lettura/scrittura fallite | 0 / 0 | 0 / 0 | 0 / 0 |

Sono **operazioni dell’intera VM**, non soli file aperti da Explorer. Includono attività di fondo e possibile paging. I tempi sono quelli del livello block QEMU, non la latenza di una chiamata Shell e non la durata completa di un’operazione sul supporto fisico del Mac. I tempi cumulativi delle richieste possono sovrapporsi: non vanno sommati alle CPU-s o sottratti dal tempo della finestra per ottenere un residuo “GPU”. La struttura dei contatori è documentata nello [schema block QAPI di QEMU](https://github.com/qemu/qemu/blob/master/qapi/block-core.json).

Le medie sub-millisecondo o prossime a 1 ms non mostrano da sole un disco virtuale costantemente lento per ogni richiesta. Non escludono una richiesta rara molto lenta, code del guest, letture del pagefile, hard fault o attese di processi diversi. Il traffico di swap dell’host percorre inoltre uno strato distinto e non è completamente descritto dai contatori del disco virtuale.

La combinazione “poche letture esplicite nel processo Explorer, molto più I/O nell’intera VM, molti page fault e attività swap host” richiede attribuzione. Non giustifica ancora un cambio di formato del disco, cache, flush, controller NVMe o durabilità.

**7. Pipeline grafica e presentazione**

Il percorso verificato nei sorgenti e attivo nelle prove è:

`Explorer / UI Windows → rendering e composizione Windows → driver VioGpu3D → QEMU e renderer Neptune/DXMT → scanout nativo condiviso → NativeDisplayReader → copia e disegno Metal nel frontend → WindowServer → screenshot del desktop Mac`.

WGC, compressione pixel del guest tool e finestre Mac individuali **non sono stadi di questo percorso**. I loro vecchi tempi non sono stati riutilizzati per completare una tabella con numeri impropri.

| Osservazione fino al primo frame conforme | B | C | D |
| --- | ---: | ---: | ---: |
| Nuove pubblicazioni del desktop | **159** | **172** | **264** |
| Nuovi ACK | 158 | 172 | 263 |
| Snapshot renderer cancellati | 16 | 27 | 20 |
| Nuovi snapshot rifiutati | **0** | **0** | **0** |
| Nuovi abbandoni esterni / drop publisher | 0 / 0 | 0 / 0 | 0 / 0 |
| Massima età dei frame pending osservata | **31 ms** | **228 ms** | **24 ms** |
| Campioni con almeno un pending non ready | 0 | 1 | 0 |
| Picco di risorse live osservato | 33 | 43 | 51 |

Le cancellazioni del renderer sono contatori di quel componente, non conteggi di frame finali sicuramente mancati sul display. I contatori di frame non sostituiscono una distribuzione FPS e non provano che ogni pubblicazione sia stata presentata fisicamente.

In B e D le età pending campionate restano nell’ordine di decine di millisecondi. In C c’è anche un’attesa maggiore osservata, 228 ms. Sono **massimi tra istantanee**, non un limite massimo garantito per ogni frame: un evento fra due campioni può sfuggire.

Il numero di pubblicazioni e ACK durante l’attesa, insieme alle immagini che mostrano prima bianco, poi sidebar e infine contenuto, è incompatibile con la sola spiegazione “un unico frame completo rimane trattenuto per tutta l’apertura nel contenitore Mac”. Non esclude un errore di sincronizzazione più a monte, contenuto parziale prodotto dal guest o stall intermittenti.

La crescita delle risorse live è una nuova osservazione pertinente a GFX-004: circa 23→33 in B, 33→43 in C, poi fino a 51 in D. Non c’è saturazione o rifiuto in queste finestre. Con poche aperture, processi e cache diversi **non è una prova di leak** né una prova di rilascio corretto a lungo termine.

**8. Copertura dei tempi, stadio per stadio**

| Stadio richiesto per spiegare l’apertura | Risultato di questa analisi | Limite |
| --- | --- | --- |
| Click/tastiera sul Mac → arrivo input Windows | Non misurato. | L’avvio è comandato nel guest; il tratto precedente a T0 non è sostituito con zero. |
| Richiesta Shell / ritorno del lancio | 291 / 1096 / 360 ms nelle tre prove. | È il ritorno della chiamata, non il tempo del primo frame. |
| Creazione/visibilità della finestra Win32 | 1392 / 3246 / 3634 ms come osservazione. | Poll nominale 10 ms, con campioni dei processi intercalati: il ritardo effettivo di rilevazione non è soltanto 10 ms. |
| Costruzione UI / enumerazione / layout / paint Explorer | Sequenza progressiva e lavoro CPU del processo misurati. | Nessuna attribuzione in stack Windows fra queste funzioni; durate interne non separabili. |
| CPU DWM, Defender e driver guest | Non attribuita quantitativamente. | Il normale token guest non permette i contatori di processo protetti usati dal probe; nessuna stima inventata. |
| Rendering guest → driver → invio al renderer host | Attività e avanzamento osservati attraverso contatori dello scanout. | Non ci sono timestamp correlati del medesimo comando o frame lungo tutto il tratto. |
| Traduzione Neptune/DXMT e GPU Apple | CPU parziale dei processi renderer; nessuna durata GPU affidabile dell’operazione. | La traccia Metal dell’apertura non è risultata utilizzabile. |
| Ready/fence, pubblicazione e ritiro | Contatori e istantanee dell’età pending. | Non è un istogramma per frame, né una misura completa della latenza. |
| Attesa `nextDrawable`, copia Metal, render e presentazione | Percorso presente nei sorgenti e CPU complessiva del frontend misurata. | Mancano timestamp esportati per ogni confine e presentazione con ID correlato. |
| Frame nel desktop Mac | Sequenza CUA con istanti prima/dopo ogni screenshot. | Include l’acquisizione; non misura l’esatto `presentedTime` del drawable né la luce emessa dal pannello. |
| Ultimo lavoro asincrono della destinazione | In D riattivazione del caricamento e successiva quiete visiva osservate. | La raccolta dei contatori termina prima della coda finale intorno a 13,20 s. |

Non è quindi corretto promettere una somma del tipo “Explorer x ms + GPU y ms + trasporto z ms = totale”. Alcuni lavori si sovrappongono e altri non sono osservati separatamente. Le lacune sono esplicite perché attribuire loro zero o un residuo sarebbe fuorviante.

Il codice attuale legge il trasporto nativo con un timer nominale di 5 ms e un massimo di due frame consegnati in sospeso. Il presenter acquisisce il drawable su una coda, importa il frame, lo copia in una texture locale, disegna e ritira la lettura dopo il completamento GPU. Sono caratteristiche del percorso, **non durate misurate di 5 ms per frame**. La callback di presentazione esiste, ma non produce qui una timeline esportata con [`MTLDrawable.presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime). I tempi [`GPUStartTime`/`GPUEndTime`](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime) non sono disponibili nel rapporto per i command buffer di questa operazione.

**9. Affidabilità, costo dell’osservazione e tentativi non riusciti**

- Gli intervalli nel guest usano QPC, frequenza rilevata 24 MHz. Prima di ogni prova valida ci sono sei scambi temporali con un server locale sull’host, raggiunto dalla rete privata della VM. Scelto lo scambio con RTT minimo; incertezza di allineamento di circa **±0,98 ms in B, ±1,81 ms in C, ±1,49 ms in D**. Sono limiti di allineamento basati sull’RTT, non una sincronizzazione hardware. [QPC e intervalli temporali](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).
- Gli screenshot hanno durata mediana di circa **77 ms**; la loro risoluzione temporale, non QPC, domina l’incertezza dei milestone visivi. Ogni immagine ha timestamp prima/dopo; non si usa il tempo di fine del comando guest come istante della sua visualizzazione.
- Il campionamento host nominale è 200 ms; nelle prove valide le chiamate diagnostiche possono dilatare l’intervallo. Sono preservati inizio/fine delle letture. Non sono stati interpolati picchi invisibili per creare percentili.
- La prima prova esplorativa A usa Metal System Trace di tutti i processi e lettura UI Automation del guest. Registra ritorno lancio a 0,621 s e finestra rilevata a 8,146 s. Una sola lettura UI Automation impiega circa **7,10 s** e porta l’osservazione oltre il limite previsto. Questi dati mostrano un costo dell’osservatore; **A non è usata come benchmark pulito o tempo visivo end-to-end**.
- L’acquisizione visiva iniziale di A non è allineata all’apertura: tentativi di usare `process.hrtime` nel runtime CUA falliscono perché il globale non esiste e l’import del modulo è vietato. Si passa a timestamp UTC prima/dopo le acquisizioni, collegati al clock host. Nessuna ricostruzione artificiale dei frame persi.
- Un controllo Metal System Trace di tre secondi riesce e salva una traccia, ma non contiene l’apertura da attribuire. La successiva traccia A raggiunge il termine e resta nella fase di salvataggio senza produrre un risultato utilizzabile per questa analisi; il coordinatore incontra timeout. Non sono estratti da quel tentativo numeri GPU dell’apertura. La prima invocazione del controllo era inoltre fallita perché non esisteva ancora la directory di destinazione: corretta prima di riprovare.
- In C Time Profiler sul solo QEMU termina e produce una traccia valida. Rimane una misura più invasiva di B/D e non dimostra che la differenza di tempi sia causata esclusivamente dal profiler.
- WPR è presente e mostra profili CPU, GPU, XAML e composizione. Un tentativo elevato di avviare una raccolta combinata non produce una ETL né un log diagnostico sufficiente; verificato infine **WPR non in registrazione**. Non è una prova che ETW sia impossibile su questa Windows ARM64. È una misura non ottenuta in questo passaggio. WPA/GPUView non risultano installati. [Microsoft WPR/WPA](https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/support-tools-xperf-wpa-wpr), [GPUView](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-gpuview).
- Il primo tentativo di estrarre gli stack host non gestisce i record senza stack; corretta l’analisi mantenendoli come **0,50% non attribuito**, non scartandoli dal denominatore. Anche l’associazione CPU è verificata sul PID realmente proprietario della finestra: in D è diverso dalla shell già esistente.

Gli strumenti non hanno overhead nullo. I risultati di B e D sono i controlli meno invasivi disponibili qui, con cattura visiva, campioni di processo e contatori; non sono prove completamente prive di osservazione. Nessun nuovo benchmark esteso o matrice di driver è stato avviato per compensare le lacune.

**10. Possibili colli di bottiglia, ordinati per utilità della prossima verifica**

| Candidato | Evidenze a favore | Cosa manca / cosa lo limita | Valutazione |
| --- | --- | --- | --- |
| Pressione di memoria Mac, compressione e swap | Swap-in/out effettivi importanti; QEMU con molto contenuto non residente nel rilievo successivo; Mac da 8 GiB; variabilità elevata. | Contatori di sistema, strumenti e altre app presenti; nessun confronto a pressione ridotta con RAM guest controllata. | **Priorità alta da isolare**. Non ancora attribuzione causale esclusiva. |
| Costruzione UI Explorer e lavoro Windows | Stadi visivi distinti; 5,3–6,3 CPU-s nel proprietario nelle finestre osservate; barra laterale e contatore precedono il corpo. | Mancano stack guest, distinzione layout/enumerazione/driver e CPU dei processi protetti. | **Contributo concreto**, meccanismo interno ancora da identificare. |
| Paging / I/O e attività di fondo Windows | Da 55 a 268 MiB di letture sul disco VM, scritture e numerosi page fault; carico QEMU elevato. | Richieste non attribuite a Explorer, fault non distinti, medie non descrivono le code. | **Candidato plausibile**, da correlare a hard fault e thread in attesa. |
| Adattamento RAM durante uso/strumentazione | Controller ordinario attivo e successivo snapshot con balloon/reclaim in corso. | Totale fisico stabile nelle singole raccolte non esclude balloon; non ci sono tutti i contatori di reclaim allineati per apertura. | **Variabile confondente concreta**, non causa dimostrata. |
| Driver / traduzione grafica / sincronizzazione | Molti aggiornamenti progressivi; esiste il difetto storico Wait/Signal GFX-007. | Nessuna riproduzione del probe fence in questo lavoro, nessuna traccia GPU completa; legame con queste aperture non dimostrato. | **Non escluso**, ma nessuna giustificazione per cambiare subito driver o protezioni. |
| Presenter Mac come collo di bottiglia dominante | Usa CPU e copia Metal; in C osservato anche pending di 228 ms. | Avanzano pubblicazioni/ACK; B/D non mostrano età pending campionate di parecchi secondi. | **Meno sostenuto come spiegazione dell’intera attesa**; non qualificato a costo nullo. |
| Rete, cartelle remote o Home/Recent | Home ha provider e contenuti asincroni in generale. | Nel caso visto ci sono sei cartelle locali e liste recenti vuote; anche Questo PC è lento, in altro processo. Nessuna attesa di rete misurata. | **Evidenza attuale debole**; evitare pulizie o disabilitazioni per tentativi. |
| Cache/shader di prima apertura | Prima apertura e nuovo processo possono inizializzare componenti. | Home resta lenta riusando lo stesso processo; nessuna durata di compilazione shader rilevata. | Possibile contributo, **non spiegazione sufficiente da sola**. |

GFX-007 resta un problema reale già documentato, ma la conoscenza di quel difetto non permette di attribuirgli automaticamente ogni comparsa tardiva di testo. Allo stesso modo, il reclaim già verificato in SYS-003 non garantisce che l’intera VM abbia un costo host basso in ogni condizione. Entrambi gli aspetti rimangono distinti dalla diagnosi prestazionale ancora aperta.

**11. Passi proposti, da scegliere dopo il report**

1. **Separare per prima la pressione di memoria.** Una sola apertura Home comparabile in condizioni di host meno sotto pressione, con RAM effettiva e balloon/reclaim registrati continuamente e invariati durante l’intervallo. Stesso percorso, risoluzione e criteri visivi. Obiettivo: vedere se si riduce proprio il tratto finestra→contenuto, non soltanto il ritorno di `explorer.exe`. Decidere esplicitamente come ottenere la condizione di confronto, senza chiudere altre app o cambiare risorse di nascosto.
2. **Attribuire il lavoro guest.** Rendere utile una breve raccolta WPR minima e diagnosticarne l’errore, prima di combinare molti profili; poi associare thread di Explorer, CPU, hard fault, I/O e layout al medesimo T0. Servono stack o eventi realmente decodificabili; se il sampling ARM/HVF non è disponibile, usare un’alternativa misurabile e dichiararne la copertura. Non installare un intero toolkit soltanto per ottenere una traccia non analizzabile.
3. **Completare i tempi grafici solo dove serve.** Se rimane una latenza rilevante dopo i controlli precedenti, aggiungere una diagnostica temporanea e disattivabile con ID coerente del frame ai confini pubblicazione, ready, import, coda MainActor, drawable, copia/disegno, completamento e presentazione. Non basta un timestamp isolato. Verificare l’overhead prima di usarla per confronti.
4. **Intervenire sul componente identificato.** Nessun cambio di RAM, cache, driver, formato disco, politica di durabilità o attivazione di modalità test è stato applicato come “ottimizzazione” in questo lavoro. Il passo successivo dovrà avere una domanda e un confronto concreto.

La prima decisione raccomandata è il confronto sulla pressione di memoria: c’è evidenza di un costo sistemico rilevante e il rischio di aumentare la RAM guest peggiorando il Mac è concreto. Se quel confronto non sposta la latenza, la priorità passa agli stack guest e al percorso UI/rendering.

**12. Evidenze e stato finale**

Le prove, le immagini e i dati grezzi restano fuori Git nella cartella privata:

`~/Library/Application Support/Perpendicular Research/Explorer-Opening-20261025/`

Contiene `A-first`, `B-home`, `C-home`, `D-thispc`, sequenze PNG e timestamp, risultati guest, campioni QMP/CPU, snapshot di `vm_stat`, allineamenti degli orologi, analisi delle regioni, riepilogo numerico, la traccia CPU valida e il riepilogo `vmmap`. Sono conservati anche i tentativi falliti e gli strumenti temporanei di misura; non sono dipendenze dell’app ordinaria. I dati grezzi includono stato locale e non vengono pubblicati insieme al report.

Il rapporto versionato conserva risultati aggregati, criteri e limiti. [Diario delle verifiche](../VERIFICATION.md#25-ottobre--analisi-apertura-explorer-nel-desktop-vm), [TODO-004 e attività correlate](../TODO.md), [registro PERF-001](../KNOWN_ISSUES.md#perf-001--explorer-nel-desktop-compare-prima-del-contenuto-completo).

App, configurazione CPU/RAM, runtime e protezioni rimangono quelli ordinari. Questo lavoro consegna l’analisi richiesta; non chiude la copertura di tutti i tempi grafici del progetto e non dichiara corretta la latenza di Explorer. Il percorso delle singole app nelle finestre Mac resta escluso da queste prove.
