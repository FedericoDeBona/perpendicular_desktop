# Registro dei problemi

Aggiornato il 24 ottobre 2026. **Leggere questo file prima di iniziare o riprendere il lavoro.** È il riferimento per lo stato corrente dei problemi; [RESTART_PLAN.md](RESTART_PLAN.md) definisce requisiti e vincoli, [VERIFICATION.md](VERIFICATION.md) conserva le prove complete e i tentativi falliti.

L'obiettivo resta rendere affidabili driver, accelerazione 3D e presentazione delle finestre, dimostrando benefici nell'app reale. Non è completato. Le candidate auto-firmate restano nella VM separata; nessuna promozione nell'app o nella VM ordinaria è stata qualificata.

## Come aggiornare il registro

- Cercare il problema esistente e aggiornare quella voce, mantenendone l'ID. Creare una nuova voce soltanto per un problema distinto.
- Indicare manifestazione, stato verificato, prossimo passo e criterio di chiusura. Distinguere osservazioni dell'utente, risultati misurati e ipotesi tecniche.
- Collegare le evidenze nel diario, senza copiarne qui tutta la cronologia. Conservare lì anche fallimenti e limiti; artefatti e dati privati delle VM restano fuori dal repository.
- Un test di laboratorio riuscito o una correzione nel clone non chiudono un problema del prodotto. Segnalare esplicitamente distribuzione e verifiche ancora mancanti.
- Aggiornare la voce a ogni cambiamento pertinente; non aggiungere prove ripetitive soltanto per cambiare lo stato. Le istruzioni più recenti dell'utente prevalgono sulle priorità qui riportate.

## Priorità corrente

La valutazione separata IVSHMEM richiesta il 24 ottobre (**TRN-001**) è conclusa: percorso fattibile nel clone e fallback riuscito, ma nessun vantaggio sul TCP+LZ4 nel testo provato; [risultati e decisione](IVSHMEM_EVALUATION.md). Conservato il trasporto ordinario. Questo non chiude né richiede di riattivare le candidate grafiche.

Isolare l'arresto del driver candidato **GFX-002** prima di riattivarlo nel compositore; risolvere il flicker **GFX-001** con un confronto reale valido. Conservare le correzioni utili di drag e resize senza legarne la distribuzione a una candidata DWM instabile. Il recupero della cattura e delle risorse è ancora aperto (**GFX-003/004**).

## Problemi aperti

### GFX-001 — Flicker e contenuti mancanti in Settings e Calcolatrice

- **Stato:** aperto, prioritario. L'utente segnala Settings molto migliorata ma ancora con flicker. Nel clone Calcolatrice riproduce pulsanti senza cifre dopo input, anche con compositore Windows in modalità standard.
- **Verificato:** alcuni PNG già ricevuti dal Mac contengono cifre mancanti prima del disegno Metal. Sei campioni completi coincidono prima/dopo compressione, ma il difetto non è comparso in quei campioni: la compressione non è esclusa per il caso parziale. Il successo delle fence non dimostra la soluzione del flicker.
- **Prossimo passo:** seguire produzione, cattura e lettura della superficie nel passaggio già difettoso. Un confronto con DWM candidato richiede prima GFX-002 risolto e una cattura effettivamente aggiornata (GFX-003).
- **Chiusura:** lo stesso passaggio prima difettoso presenta contenuti completi e aggiornati nell'app reale, con componenti identificati e poche verifiche pertinenti di input/resize. Una schermata completa isolata non basta.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), sezioni «confronto dei pixel prima e dopo il trasporto», «gate pronto prima dell'uso e frame valido al resize» e «confronto DWM non qualificato, fast-fail e recupero»; [driver](../graphics/driver/README.md).

### GFX-002 — Arresti del compositore con il driver di completamento candidato

- **Stato:** aperto; attivazione sperimentale nel compositore disabilitata. Non promuovere la candidata.
- **Verificato:** DWM cambia PID durante la prova; Windows registra arresti ripetuti in `neptune_umd_arm64.DLL`, payload `05ebb1b2a56b`, eccezione `c0000409`, RVA `1108b8`. La mappa con sezioni PE identiche identifica un helper CRT condiviso `__scrt_fastfail/_invoke_watson`; il chiamante e la causa non sono ancora individuati. Non è una diagnosi di buffer overflow.
- **Prossimo passo:** individuare chiamante e contesto del fast-fail con diagnostica mirata prima di altre varianti funzionali o riattivazioni DWM. Conservare il recupero con marker standard; la procedura temporanea non deve contare processi WMI già terminati.
- **Chiusura:** causa isolata e corretta, poi breve percorso reale con il compositore candidato, nuova cattura e ripristino riusciti. I test fence da soli non qualificano DWM.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), «confronto DWM non qualificato, fast-fail e recupero»; [limite della candidata nel produttore DWM](../graphics/driver/README.md).

### GFX-003 — Cattura ferma su un'immagine vecchia dopo il cambio del compositore

- **Stato:** aperto; recupero manuale circoscritto verificato.
- **Verificato:** Calcolatrice contiene 79 e risponde ai messaggi Windows mentre il Mac mostra 78. Riavviare il solo worker con DWM standard recupera 79 senza riavviare l'app. Il recupero automatico di questo caso non è verificato.
- **Prossimo passo:** individuare come riconoscere la sessione WGC non più valida e ricrearla, mantenendo identità della finestra, sequenze dei frame e stato dell'input coerenti.
- **Chiusura:** dopo un cambio del compositore la stessa app torna a produrre frame aggiornati senza riavvio manuale del worker, duplicazione delle finestre o uso di frame della vecchia sessione.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), «confronto DWM non qualificato, fast-fail e recupero».

### GFX-004 — Risorse grafiche indisponibili e recupero incompleto dopo i guasti

- **Stato:** aperto; causa non isolata. Un riavvio completo del clone ripristina il percorso, ma non è recupero automatico.
- **Verificato:** dopo gli arresti ripetuti anche DWM standard registra `MILERR_NO_HARDWARE_DEVICE`; una nuova cattura fallisce nella creazione dello staging con `E_OUTOFMEMORY`, pur riportando device status `S_OK`. Il solo ripristino del marker/worker non basta sempre. Non è dimostrata una specifica perdita di memoria.
- **Prossimo passo:** correlare le risorse ancora possedute da guest, renderer e contesti usciti, usando il guasto conservato; circoscrivere il componente che non recupera prima di cambiare limiti o aggiungere retry.
- **Chiusura:** il guasto identificato rilascia le risorse e consente una nuova cattura e una finestra utilizzabile senza spegnere l'intera VM.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), ultimo confronto DWM. Il recupero dopo boot mostra Calcolatrice con il valore 12 e 11 frame presentati, senza errore; questo non chiude la voce.

### GFX-005 — Desktop di recupero nero nel percorso multi_ring

- **Stato:** aperto, limitato al percorso sperimentale. Non estendere questa diagnosi a ogni configurazione del desktop.
- **Verificato:** il renderer ora rifiuta esplicitamente la cattura iniziale non supportata senza terminare il worker o impedire nuovi contesti; il desktop resta nero. La correzione del rifiuto non implementa la cattura su più code.
- **Prossimo passo:** definire un percorso di cattura compatibile con lo scheduling effettivo, mantenendo i controlli che vietano snapshot non sicuri.
- **Chiusura:** il desktop di recupero mostra contenuti aggiornati ed è utilizzabile nella configurazione grafica proposta per il prodotto, anche quando una singola finestra non funziona.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md) e [driver](../graphics/driver/README.md), «Pacchetto ARM64X e limite della cattura multi_ring»; [renderer](../graphics/renderer/README.md).

### GFX-006 — Risoluzione e DPI errati dopo installazione del driver a caldo

- **Stato:** aperto; recupero dopo avvio completo verificato nel clone.
- **Verificato:** dopo l'installazione Windows può tornare1024×768/DPI96; la verifica della modalità 2880×1740 riesce ma l'applicazione restituisce errore. Riconnettere il frontend non basta; un nuovo avvio ripristina 2880×1740/DPI192.
- **Prossimo passo:** prima di distribuire il pacchetto definire quando l'aggiornamento richiede riavvio e confermare la topologia prima di riabilitare geometria e input condivisi.
- **Chiusura:** aggiornamento e riavvio eventualmente richiesto portano al display concordato; l'app non presenta come confermata una geometria non applicata.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), «gate pronto prima dell'uso e frame valido al resize».

## Correzioni nel clone: distribuzione ancora da completare

### WIN-001 — Drag Mac/Windows con spostamenti casuali

- **Stato:** causa concreta corretta e verificata nel clone; non dichiarare risolto in ogni configurazione o nell'app ordinaria.
- **Correzione:** posizione e metadati del mouse sono conservati prima dell'accodamento; `NSEvent.cgEvent` poteva ricostruire le coordinate usando l'origine della finestra già spostata. Commit `21d206b`.
- **Verificato:** prova AppKit e breve uso reale di Settings/Calcolatrice sul primario Retina, spostamenti coerenti e input successivo funzionante.
- **Da completare / chiusura:** confezionare e qualificare la correzione nel pacchetto destinato all'utente. Il passaggio fra monitor non è verificato: resta WIN-003.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), correzione del drag del 24 ottobre; [RESTART_PLAN.md](RESTART_PLAN.md), «Ripresa dopo prova utente: drag e flicker».

### WIN-002 — Resize che resta in attesa del nuovo frame

- **Stato:** caso corretto e verificato nel clone; distribuzione ordinaria da completare.
- **Correzione:** quando la texture WGC contiene già il nuovo rettangolo, il worker legge e pubblica quel frame prima di ricreare il pool. Commit `36378af`, worker `8042269f942a`.
- **Verificato:** lo stesso rimpicciolimento di Calcolatrice da 644×1252 a 644×1232, prima bloccato, presenta il nuovo frame senza input o redraw aggiuntivo.
- **Da completare / chiusura:** qualificare il percorso nel pacchetto destinato all'utente con una breve prova pertinente; il successo del resize non chiude flicker o recupero generale.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), «gate pronto prima dell'uso e frame valido al resize».

### GFX-007 — Fence Wait/Signal e completamento delle scritture GPU

- **Stato:** correzioni sperimentali verificate in laboratorio; integrazione affidabile e beneficio reale ancora aperti.
- **Verificato:** Wait passa dal callback runtime precedentemente vuoto al contesto di scheduling; il controllo resta pendente con fence0 e termina dopo Signal indipendente. Il controllo di pubblicazione individua anche fence1 con vecchi pixel; con gate di completamento e renderer abbinato restituisce i pixel corretti. Le chiamate restano asincrone. Corretto anche l'uso del ring prima della conferma di creazione.
- **Da completare / chiusura:** risolvere GFX-002 e dimostrare che la correzione elimina un problema concreto come GFX-001 nel pacchetto reale. Non ripetere i controlli già superati senza una modifica pertinente; non dedurre stabilità generale dalla riuscita dei test.
- **Evidenze:** [test Wait](../tests/WindowsFenceWaitChecks.cs), [test pubblicazione](../tests/WindowsFencePublicationChecks.cs), [driver](../graphics/driver/README.md), [renderer](../graphics/renderer/README.md), [VERIFICATION.md](VERIFICATION.md). La [segnalazione upstream](https://github.com/osy/kvm-guest-drivers-windows/issues/8) conserva il difetto originario, non certifica le candidate locali.

## Esperimento di trasporto separato

### TRN-001 — IVSHMEM non disponibile nel QEMU macOS attuale

- **Stato:** chiusa la valutazione di fattibilità richiesta, con esito di non adozione per il prodotto. Mapping/pubblicazione/riuso/notifica, frame WGC esatti e fallback verificati nel clone separato. Il QEMU ordinario resta privo del device; nessuna distribuzione o qualifica generale.
- **Verificato:** QEMU Native3D 10.0.12/hash `64a5e90ee941` locale, incluso nel bundle e nel runtime del clone non registra `ivshmem-plain`. La patch proposta non si applica direttamente allo snapshot associato: file rinominato `ivshmem-pci.c`, hunk Kconfig incompatibile; resta anche un gate Meson su EVENTFD. La patch esclude il doorbell su macOS. Sorgente driver KMDF con configurazioni ARM64 e API mapping/MMIO individuato; pacchetto Fedora ARM64 del2022 individuato (SYS Aarch64, INF e CAT con certificato Microsoft); catalogo Valid, installazione exit0 e servizio Running verificati nel nuovo clone con Secure Boot1, SYS0188b04ec1e2 senza modifiche o nuova firma.
- **Incremento host:** device distinto `perp-ivshmem-plain`, BAR0 conservata (rimossa dalla patch originale senza doorbell), BAR2 e notifica MMIO→socket Unix; 1186 input verificati, baseline ricostruita con codice identico al QEMU corrente, pattern bidirezionali e notifica riusciti via qtest/HVF, senza dischi. Non è una prova di store/barriere Windows.
- **Incremento Windows:** user mapping64MiB noncached, sfida4096byte letta correttamente, due payload completi alla notifica MMIO→socket. Slot1 trattenuto2s: tentativo di riuso respinto dal probe e byte invariati; dopo ACK1 pubblicazione2/ACK2 riuscita. Barriere esplicite guest/Mac, nessun polling del ricevitore. È una verifica della piccola prova, non del trasporto frame Rust.
- **Incremento frame:** overlay Rust/Swift solo privato: tre slot con epoch e copie grezze, MMIO→socket→buffer Metal posseduto, ACK TCP esistente per confronto a una consegna pendente. Blocco note hardware2178×1303/11.674.880byte presentato e testo digitato leggibile; dopo disabilitazione IVSHMEM stessa finestra su TCP raw, ID e testo conservati, input successivo visibile. Nessuna copia GPU Windows eliminata.
- **Confronto conclusivo:** stesso Blocco note2178×1303/11.674.880byte, tre brevi attività identiche. Mediana selezione WGC→callback Metal: IVSHMEM 19,50 ms, TCP raw 237,63 ms, TCP+LZ4 16,10 ms; p95: 95,10/324,32/33,54 ms. Tre hash completi uguali, sequenze ricevute senza buchi e tutte presentate; raw accorpa più acquisizioni prima della pubblicazione. Sei tempi SystemRelativeTime negativi del primo confronto conservati e non qualificati; nuova misura parte dal QPC di selezione, esclude input→schermo. CPU/clock e confini dei conteggi nel documento dedicato.
- **Decisione / seguito:** TCP+LZ4 rimane ordinario; IVSHMEM evita il payload TCP ma non supera LZ4 sul testo provato. Nessuna migrazione controllo né modifica grafica. Eventuale contenuto poco comprimibile o integrazione robusta richiedono un seguito esplicito, non altre prove per chiudere questo esperimento. Servizio normale ripristinato, zero worker/task temporanei, ACPI/checkpoint 143841Z pulito; disco/EFI e binari ordinari invariati.
- **Criterio soddisfatto nel clone:** stessa memoria osservata da Windows/Mac, pubblicazione completa prima della notifica e nessun riuso durante la lettura; frame reale e fallback TCP verificati; breve confronto raw/raw e contro TCP+LZ4 con decisione motivata anche se negativa. Nessuna promessa zero-copy completo o soluzione GFX per deduzione.
- **Evidenze:** [confronto conclusivo e limiti](VERIFICATION.md#24-ottobre--ivshmem-frame-esatti-confronto-breve-e-decisione), con rimandi ai passaggi precedenti; [valutazione e contratto](IVSHMEM_EVALUATION.md).

## Limiti e lavoro rinviato

### WIN-003 — Più monitor e drag fra scale diverse

- **Stato:** integrazione completa dei monitor Windows non disponibile; geometria e drag recenti verificati soltanto sul primario Retina. La presenza di un secondo monitor Mac non è una prova di supporto.
- **Prossimo passo / chiusura:** quando pertinente, confermare topologia e DPI guest e verificare un singolo passaggio fra monitor con immagine, posizione e input coerenti. Non allargare le prove del drag sul primario per compensare questa capacità mancante.
- **Riferimenti:** [requisiti monitor e scala](RESTART_PLAN.md), [limiti del prodotto](../README.md), [VERIFICATION.md](VERIFICATION.md).

### APP-001 — Compatibilità specifica di Creality / OpenGL

- **Stato:** rinviato per richiesta esplicita dell'utente. L'avvio dell'area di lavoro in modalità software non qualifica il rendering OpenGL o l'uso completo dell'app.
- **Prossimo passo:** riprendere soltanto su nuova priorità dell'utente o necessità concreta del percorso attivo; conservare le evidenze senza riaprire configurazioni o prove specifiche per completismo.
- **Riferimenti:** [RESTART_PLAN.md](RESTART_PLAN.md) e [VERIFICATION.md](VERIFICATION.md), prove Creality e successivo rinvio.
