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

**Richiesta aggiornata: uso dentro la VM tramite «Apri Windows».** L’utente riferisce un desktop molto fluido e piacevole; dare ora priorità a driver, presentazione del desktop e uso quotidiano in questa modalità. Finestre individuali Mac↔Windows, WGC→GPU, IVSHMEM/codec/dirty region e topologia N+1/debug monitor sono conservati e rinviati. Il riscontro è una valutazione d’uso, non una nuova misura di latenza o prova di affidabilità generale. [Cambio di priorità e riscontro](VERIFICATION.md#24-ottobre--priorità-al-desktop-windows-diretto).

Ordine aggiornato nella nuova chat: (1) breve riproduzione in «Apri Windows» dei contenuti Settings/Calcolatrice durante input, menu, scroll e resize; (2) correggere soltanto cause concrete distinguendo app, composizione Windows e presentazione Mac; se il difetto non compare, registrare il limite e proseguire; (3) modalità desktop dedicata senza catalogo obbligatorio o catture individuali automatiche; (4) sessione/input dopo riapertura; (5) **solo +1**, un monitor Windows con vera risoluzione adattata alla vista Mac e al fullscreen, scala Retina/input coerenti, richieste seriali e risposte effettive. Nessun monitor N aggiuntivo in questa fase. Conservare la candidata DWM instabile disattivata e APP-001 rinviato. Questi sono requisiti, non capacità già qualificate.

**Incremento corrente verificato nel clone:** pacchetto privato DesktopFocus/build-4 apre direttamente il desktop; controllo VM/guest disponibile, frameChannel=false, nessuna finestra individuale. Worker5588/d6d0da93aebc differisce dal precedente3df: ripristino catture soltanto dopo richiesta esplicita del canale finestre. Stesso QEMU25490 e documento Notepad7936; nessun reboot/driver/ordinario modificato. Finestra1920×1200↔fullscreen2880×1740 confermati nel guest e nello scanout nativo; chiusura viewer con VM accesa e riapertura/input riusciti. Corretto conflitto fra query display e configurazione. [Prove e limiti](VERIFICATION.md#24-ottobre--desktop-dedicato-e-primo-resize-su-un-solo-monitor).

**Da completare:** DPI/dimensione percepita stabile (Windows sceglie150% in finestra e200% fullscreen); risoluzioni limitate ai modi pubblicizzati, quindi bande/scaling residuo possibili. Avvio a freddo e distribuzione ordinaria non qualificati. Non usare cleanup storici3df sul nuovo worker. Host-7/candidata DWM disattivata invariati; WGC individuale conservato senza fallback frame TCP.

## Problemi aperti

### GFX-001 — Flicker e contenuti mancanti in Settings e Calcolatrice

- **Stato:** aperto, prioritario. L'utente segnala Settings molto migliorata ma ancora con flicker. Nel clone Calcolatrice riproduce pulsanti senza cifre dopo input, anche con compositore Windows in modalità standard.
- **Verificato:** alcuni PNG già ricevuti dal Mac contengono cifre mancanti prima del disegno Metal. Sei campioni completi coincidono prima/dopo compressione, ma il difetto non è comparso in quei campioni: la compressione non è esclusa per il caso parziale. Il successo delle fence non dimostra la soluzione del flicker.
- **Priorità desktop:** breve prova Settings/Calcolatrice nel desktop: testi/cifre/menu completi e scroll aggiornato, nessuna riproduzione delle cifre mancanti persistenti; transizione di layout alla massimizzazione osservata, non qualifica assenza di flicker. [Prova corrente](VERIFICATION.md#24-ottobre--desktop-dedicato-e-primo-resize-su-un-solo-monitor). Conservare una riproduzione concreta prima di cambiare driver; il riscontro positivo dell’utente non chiude il caso WGC né dimostra una correzione nel driver. [Cambio di priorità](VERIFICATION.md#24-ottobre--priorità-al-desktop-windows-diretto).
- **Prossimo passo:** seguire produzione, cattura e lettura della superficie nel passaggio già difettoso, solo se pertinente alla modalità attiva. Un confronto con DWM candidato richiede prima GFX-002 risolto e una cattura effettivamente aggiornata (GFX-003).
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
- **Seguito solo GPU:** dopo reconnect primo frame GPU vuoto/incompleto e hash coerente con la sorgente; il gate iniziale non lo mostra. Apertura del desktop/attivazione della finestra di prova seguite da nuova immagine completa e testo visibile, senza passare a TCP. Focus/input iniziale resta intermittente; causa non isolata e nessuna soluzione generale dichiarata. [Evidenze](VERIFICATION.md#24-ottobre--richiesta-solo-gpu-rimozione-fallback-e-riavvio-frontend).
- **Sintomo simile, causa distinta verificata nella candidata GPU:** una finestra successiva era rifiutata dal proprietario globale mai rilasciato; il frontend mostrava solo «non è ancora pronta». Gate rimosso e ACK reso specifico per immagine; stesso documento/HWND tornato visibile, seconda app chiusa/riaperta con tre hash esatti per cattura. Correzione distribuita soltanto nel clone build-7. Non chiude il caso di immagine vecchia dopo cambio compositore. [Evidenze](VERIFICATION.md#24-ottobre--finestra-aperta-ma-non-pronta-correzione-del-proprietario-gpu).
- **Prossimo passo:** individuare come riconoscere la sessione WGC non più valida e ricrearla, mantenendo identità della finestra, sequenze dei frame e stato dell'input coerenti.
- **Chiusura:** dopo un cambio del compositore la stessa app torna a produrre frame aggiornati senza riavvio manuale del worker, duplicazione delle finestre o uso di frame della vecchia sessione.
- **Evidenze:** [VERIFICATION.md](VERIFICATION.md), «confronto DWM non qualificato, fast-fail e recupero».

### GFX-004 — Risorse grafiche indisponibili e recupero incompleto dopo i guasti

- **Stato:** aperto; causa non isolata. Un riavvio completo del clone ripristina il percorso, ma non è recupero automatico.
- **Verificato:** dopo gli arresti ripetuti anche DWM standard registra `MILERR_NO_HARDWARE_DEVICE`; una nuova cattura fallisce nella creazione dello staging con `E_OUTOFMEMORY`, pur riportando device status `S_OK`. Il solo ripristino del marker/worker non basta sempre. Non è dimostrata una specifica perdita di memoria.
- **Nuova osservazione nel clone WGC GPU:** il broker chiude globalmente la cattura dopo `producer completion timeout` e rifiuta nuovi contesti; WGC resta in starting con `0x887A0004`. Il controllo si riconnette ma i frame non recuperano. Rapporto causale fra hook sperimentale e guasto non isolato. Ripristino del runtime precedente e nuovo boot riportano una finestra hardware utilizzabile; non è recupero automatico. [Prova e ripristino](VERIFICATION.md#24-ottobre--prova-wgc-gpu-non-qualificata-e-ripristino-tcp).
- **Seguito WGC GPU:** nuova sessione con layout/cache finali e sola diagnostica aggiuntiva presenta frame esatti e fallback, senza timeout durante il tratto osservato. Nessuna correzione causale del timeout verificata; non chiudere questa voce per la riuscita. [Evidenze](VERIFICATION.md#24-ottobre--wgc-gpu-primi-frame-esatti-fallback-e-confronto-breve).
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

- **Stato:** chiusa la valutazione di fattibilità richiesta, con esito di non adozione per il prodotto; seguito combinato provato, poi terminato durante il successivo esperimento WGC GPU. Mapping/pubblicazione/riuso/notifica, frame WGC esatti e fallback verificati nel clone separato. Il QEMU ordinario resta privo del device; nessuna distribuzione o qualifica generale.
- **Verificato:** QEMU Native3D 10.0.12/hash `64a5e90ee941` locale, incluso nel bundle e nel runtime del clone non registra `ivshmem-plain`. La patch proposta non si applica direttamente allo snapshot associato: file rinominato `ivshmem-pci.c`, hunk Kconfig incompatibile; resta anche un gate Meson su EVENTFD. La patch esclude il doorbell su macOS. Sorgente driver KMDF con configurazioni ARM64 e API mapping/MMIO individuato; pacchetto Fedora ARM64 del2022 individuato (SYS Aarch64, INF e CAT con certificato Microsoft); catalogo Valid, installazione exit0 e servizio Running verificati nel nuovo clone con Secure Boot1, SYS0188b04ec1e2 senza modifiche o nuova firma.
- **Incremento host:** device distinto `perp-ivshmem-plain`, BAR0 conservata (rimossa dalla patch originale senza doorbell), BAR2 e notifica MMIO→socket Unix; 1186 input verificati, baseline ricostruita con codice identico al QEMU corrente, pattern bidirezionali e notifica riusciti via qtest/HVF, senza dischi. Non è una prova di store/barriere Windows.
- **Incremento Windows:** user mapping64MiB noncached, sfida4096byte letta correttamente, due payload completi alla notifica MMIO→socket. Slot1 trattenuto2s: tentativo di riuso respinto dal probe e byte invariati; dopo ACK1 pubblicazione2/ACK2 riuscita. Barriere esplicite guest/Mac, nessun polling del ricevitore. È una verifica della piccola prova, non del trasporto frame Rust.
- **Incremento frame:** overlay Rust/Swift solo privato: tre slot con epoch e copie grezze, MMIO→socket→buffer Metal posseduto, ACK TCP esistente per confronto a una consegna pendente. Blocco note hardware 2178×1303/11.674.880 byte presentato e testo digitato leggibile; dopo disabilitazione IVSHMEM stessa finestra su TCP raw, ID e testo conservati, input successivo visibile. Nessuna copia GPU Windows eliminata.
- **Confronto conclusivo:** stesso Blocco note2178×1303/11.674.880 byte, tre brevi attività identiche. Mediana selezione WGC→callback Metal: IVSHMEM 19,50 ms, TCP raw 237,63 ms, TCP+LZ4 16,10 ms; p95: 95,10/324,32/33,54 ms. Tre hash completi uguali, sequenze ricevute senza buchi e tutte presentate; raw accorpa più acquisizioni prima della pubblicazione. Sei tempi SystemRelativeTime negativi del primo confronto conservati e non qualificati; nuova misura parte dal QPC di selezione, esclude input→schermo. CPU/clock e confini dei conteggi nel documento dedicato.
- **Decisione / seguito:** TCP+LZ4 rimane ordinario; IVSHMEM evita il payload TCP ma non supera LZ4 sul testo provato. Nessuna migrazione controllo né modifica grafica. Eventuale contenuto poco comprimibile o integrazione robusta richiedono un seguito esplicito, non altre prove per chiudere questo esperimento. Servizio normale ripristinato, zero worker/task temporanei, ACPI/checkpoint 143841Z pulito; disco/EFI e binari ordinari invariati.
- **Ricerca compressione richiesta in seguito:** selezionato un unico candidato, LZ4 block indipendente con lz4_flex 0.14.0/decoder Apple già presenti. Esaminati anche Zstd fast e QOI/QOIR, senza nuovi benchmark. Il vantaggio della compressione su IVSHMEM resta un'ipotesi: conclusione raw conservata; al momento della ricerca non erano implementati codec o nuova sessione, poi aggiunti nel seguito sotto. [Scelta e proposta minima](IVSHMEM_EVALUATION.md#compressione-su-ivshmem-un-solo-candidato), [fonti e limiti](VERIFICATION.md#24-ottobre--ivshmem-ricerca-compressione-e-selezione-di-lz4).
- **Prova dirty regions eseguita:** overlay privato ReportOnly con readback completo come oracolo. In 23 frame di aggiornamenti piccoli, 19 patch esatte, 3 ricostruzioni insufficienti (679/309/461byte) inviate full e 1 reset base full; 23 ricevuti/presentati con hash completi uguali. Aggiornamento testo 359.064 byte contro 11.674.880 raw; campione inclusi full −81,92% di payload. Validazione guest mediana 60,54 ms, readback e copia base Mac completi: nessun vantaggio di latenza qualificato. Nessuno skip visibile nel tratto, causa della copertura non isolata. Fallback TCP/stessa finestra e input E riusciti; servizio ripristinato, ACPI/checkpoint 150806Z, ordinario invariato. [Prova e limiti](IVSHMEM_EVALUATION.md#prova-dei-rettangoli-grezzi-nel-clone), [diario](VERIFICATION.md#24-ottobre--ivshmem-prova-rettangoli-con-riferimento-completo-e-tre-coperture-insufficienti). Prima di eliminare l'oracolo o ridurre il readback, qualificare la copertura nei casi falliti; niente rendering parziale o deduzioni sui GFX.
- **Prova combinata storica, ora terminata:** LZ4 su full/rettangoli con ramo raw piccolo; 18 frame ricevuti/presentati, 12 hash complete uguali, 6 successivi senza hash; una copertura insufficiente di 471 byte protetta da full. Limite SHA ai primi 12 frame, confronto guest completo mantenuto sempre: validazione senza hash mediana 65,04 ms nel piccolo campione, nessun miglioramento di latenza dimostrato. In quella sessione Blocco note era pronto all’uso nel frontend privato; menu di ritorno TCP+LZ4 presente ma non attivato. Primo boot non collegato, ACPI scaduto e QMP quit del solo clone; secondo boot collegato senza restore. Allora servizio standard del clone **Stopped**, worker temporaneo **de10af3968c0** attivo; stato superato dal ripristino del seguito GPU sotto. Ordinario disco/EFI/binari invariati. [Stato, costo e limiti](IVSHMEM_EVALUATION.md#prova-interattiva-combinata-lasciata-accesa), [evidenze e ripristino](VERIFICATION.md#24-ottobre--ivshmem-lz4-e-rettangoli-avvio-per-prova-utente).
- **Alternativa WGC→GPU, primo percorso verificato nel seguito:** precedenti fallimenti conservati. Nuova sessione passa tre hash pixel, presentazione/input GPU e fallback manuale stessa finestra/documento su TCP+LZ4. Frame successivi senza readback pixel nel worker; due copie GPU restano. Confronto identico97/97 frame: mediana50,89/58,29ms e p95 139,68/136,54ms (GPU/TCP+LZ4), worker CPU0,531/0,766s. Migliore mediana nel campione, nessuna superiorità generale o soluzione GFX. Stato successivo richiesto: solo immagini GPU senza fallback manuale/automatico; handoff corrente build-7/host-7 e worker3dfd6b8d422e, servizio Stopped e Worker senza trigger. Rimosso il limite del proprietario globale non rilasciato, ACK per pacchetto; due finestre e riapertura circoscritte verificate. [Correzione del blocco](VERIFICATION.md#24-ottobre--finestra-aperta-ma-non-pronta-correzione-del-proprietario-gpu). Il confronto precedente resta storico, non ripetuto dopo la rimozione. [Riavvio solo GPU](VERIFICATION.md#24-ottobre--richiesta-solo-gpu-rimozione-fallback-e-riavvio-frontend). Nessuna modifica driver/ordinario. [Prototipo](../experimental/wgc-gpu/README.md), [diario e handoff](VERIFICATION.md#24-ottobre--wgc-gpu-primi-frame-esatti-fallback-e-confronto-breve).
- **Criterio soddisfatto nel clone:** stessa memoria osservata da Windows/Mac, pubblicazione completa prima della notifica e nessun riuso durante la lettura; frame reale e fallback TCP verificati; breve confronto raw/raw e contro TCP+LZ4 con decisione motivata anche se negativa. Nessuna promessa zero-copy completo o soluzione GFX per deduzione.
- **Evidenze:** [confronto conclusivo e limiti](VERIFICATION.md#24-ottobre--ivshmem-frame-esatti-confronto-breve-e-decisione), con rimandi ai passaggi precedenti; [valutazione e contratto](IVSHMEM_EVALUATION.md).

## Limiti e lavoro rinviato

### WIN-003 — Più monitor e drag fra scale diverse

- **Stato:** integrazione completa dei monitor Windows non disponibile; geometria e drag recenti verificati soltanto sul primario Retina. La presenza di un secondo monitor Mac non è una prova di supporto.
- **Direzione utente valutata:** N monitor guest corrispondenti ai Mac più area «Apri Windows» riservata, con trasferimenti espliciti; proposta accettata dall’utente, richiesti anche pulsanti per aprire le singole uscite Windows a scopo debug; preferita topologia stabile rispetto a un unico monitor ridimensionato per finestra. N+1 nella stessa sessione non isola i desktop: riserva via policy Perpendicular è proposta, non garanzia di invisibilità degli altri monitor. Una GPU multi-output è prima scelta da verificare; driver diversi richiedono adattatori distinti e non isolano DWM. Attuale QEMU max_outputs=1/configurazione guest solo primario. [Requisiti e vincoli](RESTART_PLAN.md#direzione-concordata--monitor-mac-più-area-windows-riservata-wgc-su-gpu), [fonti/evidenze](VERIFICATION.md#24-ottobre--valutazione-n1-monitor-isolamento-e-gpu-per-schermo).
- **Priorità aggiornata:** N+1 e finestre Mac individuali rinviati mentre si consolida «Apri Windows»; non cambiare topologia come prerequisito del desktop attuale. [Decisione](VERIFICATION.md#24-ottobre--priorità-al-desktop-windows-diretto).
- **Prossimo passo / chiusura, quando ripreso:** qualificare due uscite reali e DPI nel clone prima di N+1; poi trasferire una finestra con dialogo/documento fra area riservata e integrazione Mac, e verificare un passaggio fra monitor con immagine, posizione e input coerenti. L’export WGC→GPU resta prova distinta e può partire sul singolo monitor. Non allargare le prove del drag sul primario per compensare questa capacità mancante.
- **Riferimenti:** [requisiti monitor e scala](RESTART_PLAN.md), [limiti del prodotto](../README.md), [VERIFICATION.md](VERIFICATION.md).

### APP-001 — Compatibilità specifica di Creality / OpenGL

- **Stato:** rinviato per richiesta esplicita dell'utente. L'avvio dell'area di lavoro in modalità software non qualifica il rendering OpenGL o l'uso completo dell'app.
- **Prossimo passo:** riprendere soltanto su nuova priorità dell'utente o necessità concreta del percorso attivo; conservare le evidenze senza riaprire configurazioni o prove specifiche per completismo.
- **Riferimenti:** [RESTART_PLAN.md](RESTART_PLAN.md) e [VERIFICATION.md](VERIFICATION.md), prove Creality e successivo rinvio.
