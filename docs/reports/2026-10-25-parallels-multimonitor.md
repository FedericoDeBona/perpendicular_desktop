# Parallels: più schermi Windows e finestre integrate sul Mac

> Seguito sperimentale successivo: superato nel clone il blocco iniziale della strada mista protetta3D+DOD, con tre uscite reali, pixel/input e nuovo boot. N+1 integrato/main resta da completare; le conclusioni statiche su Parallels qui sotto restano circoscritte. [Evidenze aggiornate](../VERIFICATION.md#25-ottobre--todo-001-alternative-protette-e-associazione-per-dispositivo).

Ricerca del 25 ottobre 2026, richiesta per TODO-001 dopo la prova negativa degli adattatori misti. Analisi statica con REA/Ghidra dei componenti installati di **Parallels Desktop 27.0.3, build 58680**, integrata con fonti primarie online. Nessuna VM avviata, nessun Tools installato, nessuna modifica alla main o alle protezioni Windows.

## Risposta pratica

**Sì: Parallels realizza l'integrazione fra più schermi Mac, schermi Windows e singole finestre Windows visibili sul Mac. Il suo driver ARM64 contiene già il supporto per più uscite nello stesso adattatore grafico.** Questo è il riscontro più utile per il progetto: una GPU virtuale può esporre più schermi, senza dover aggiungere una GPU per ogni schermo.

**Non è invece dimostrato che Parallels usi il nostro preciso schema N+1**, con un'ulteriore area desktop riservata ad «Apri Windows». Non ho trovato un'uscita con questo ruolo identificabile nei percorsi esaminati. La somiglianza verificata riguarda multischermo e integrazione delle finestre, non questa scelta di prodotto.

## Cosa confermano le fonti pubbliche

Parallels descrive la disposizione degli schermi come guidata dal Mac: rileva l'arrangiamento macOS e lo applica alla VM; non richiede di collegare direttamente il monitor fisico a Windows. La guida riguarda la modalità fullscreen e non documenta il protocollo interno. [KB122901, revisione 2022](https://kb.parallels.com/en/122901).

Coherence presenta le app Windows insieme alle app Mac, nasconde il desktop Windows e integra Dock e gestione delle finestre; richiede Parallels Tools. Questa è una capacità del prodotto documentata, non una deduzione dai nomi delle funzioni. [KB4670, revisione 2023](https://kb.parallels.com/en/4670).

Una precedente procedura per Coherence multimonitor richiede il Parallels Display Adapter funzionante e schermi Windows estesi. È documentazione del 2019, quindi non prova l'implementazione ARM64 corrente; conferma però che Coherence si appoggia anche alla topologia display del guest. [KB112373](https://kb.parallels.com/en/112373).

## Cosa ho trovato davvero con REA

### 1. Un adattatore Windows con più uscite

Il pacchetto ARM64 originale incluso nell'app contiene `prl_dd.inf`, il miniport kernel `prl_kmdd.sys` e driver grafici user-mode, inclusi componenti Direct3D. L'INF dichiara **Parallels Display Adapter (WDDM)**, servizio `prl_dd`, versione `20.18.2703.58680`; su ARM64 il dispositivo è `ACPI\VEN_PRL&DEV_4005`. Non è il dispositivo VirtIO usato da Perpendicular.

La parte decisiva non è una stringa “multimonitor”. Ho seguito con REA la registrazione delle callback del driver e due callback effettive:

- **StartDevice, indirizzo `0x140025470`:** conserva nel contesto del singolo adattatore un conteggio di sorgenti/uscite. Nel percorso esaminato il valore richiesto viene limitato a **10**, con ripiego a **1** se è zero. Il medesimo conteggio viene restituito a Windows come numero di sorgenti di presentazione e numero di dispositivi figli.
- **QueryChildRelations, `0x140023e10`:** legge quel conteggio e costruisce un descrittore per ciascuna uscita, con identificativi distinti `0…conteggio−1`. Non crea nuovi adattatori per enumerarle.

L'identificazione delle callback deriva dalla tabella registrata dal driver, confrontata con il layout ufficiale Microsoft, non da nomi originali recuperati dal binario. [DRIVER_INITIALIZATION_DATA](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-_driver_initialization_data), [StartDevice](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_start_device), [QueryChildRelations](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_query_child_relations).

**Conclusione statica forte:** questo driver può dichiarare più sorgenti e uscite per adattatore. Il limite 10 è una proprietà del percorso analizzato, **non una prova di dieci monitor simultaneamente attivi o del limite commerciale del prodotto**. I descrittori includono anche uscite potenziali: enumerare un'uscita e avere uno schermo collegato/attivo sono cose diverse. [Semantica dei descrittori Microsoft](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-_dxgk_child_descriptor).

### 2. Il Mac invia configurazioni e riceve immagini delle uscite

Il frontend Mac attuale `prl_client_app` importa realmente le API del suo SDK per configurazione display, dimensioni, buffer, contesto schermo e notifica dello stato Coherence. Importa inoltre IOSurface e funzioni per rilevare aggiunta/rimozione di schermi Mac.

L'analisi REA precedente dello **stesso identico SDK, verificato tramite SHA256**, mostra che `PrlDevDisplay_SetConfiguration` controlla gli argomenti e inoltra una configurazione composta da più record. Sono presenti anche `GetScreenSize` e `SyncSetScreenSurface`.

Questi elementi sono coerenti con un host che governa la topologia e presenta le immagini delle uscite. **Non dimostrano** che la configurazione sia sempre applicata, un percorso zero-copy, la sequenza completa delle fence o che tutte quelle API siano eseguite in ogni modalità. Un ACK non sostituisce il riscontro della geometria effettiva, anche nel nostro progetto.

### 3. Coherence ha un agente guest e hook dedicati alle finestre

Il pacchetto corrente contiene `coherence.exe` ARM64 e `prl_hook.dll`. L'agente importa operazioni per snapshot delle finestre, bounds DWM, icone, spostamento e dimensionamento, oltre alle normali API Windows per posizione e focus.

REA mostra un percorso concreto in `coherence.exe`, funzione `0x140002870`: apre il canale dispositivo `prl_tg`, gestisce eventi di avvio/arresto/disconnessione Coherence, attiva/disattiva `DashHook` e, su un messaggio ricevuto, chiama `DashSnapshotWindows`. È quindi presente coordinamento esplicito nel guest, oltre alla presentazione sul Mac.

**Non ho ricostruito il formato completo dello snapshot né il percorso dei pixel di ogni finestra.** Il nome “snapshot” da solo non significa screenshot; le importazioni dei bounds non provano dove venga eseguito il ritaglio. Non è dimostrato né escluso l'uso di WGC in altri componenti o percorsi.

## Il modello che emerge e cosa resta ignoto

La ricostruzione supportata è: **disposizione degli schermi Mac → configurazione delle uscite virtuali → driver WDDM capace di più uscite**, accompagnata da **agente Coherence nel guest e frontend sul Mac per integrare le finestre**. I singoli componenti e i percorsi sopra sono osservati; il collegamento end-to-end fra tutti gli stadi resta una ricostruzione, non una traccia runtime.

| Domanda | Risposta sostenuta dalle prove |
| --- | --- |
| Una GPU per monitor? | Non necessaria: il miniport contiene più sorgenti/uscite per singolo adattatore. Questo non inventaria tutte le possibili configurazioni Parallels. |
| Uno schermo virtuale per ogni app? | Non dimostrato; gli hook dedicati mostrano un livello separato di gestione delle finestre. |
| Un desktop nascosto aggiuntivo N+1? | Non confermato né escluso. |
| Ogni app è isolata dalle altre? | Nessuna prova; nascondere il desktop non costituisce isolamento. |
| Coherence evita WGC, copie o problemi di sync? | Non stabilito da questa analisi. Nessuna misura di prestazioni eseguita. |
| La firma è compatibile con il vincolo di prodotto? | Il catalogo ARM64 contiene un certificato Microsoft Windows Hardware Compatibility Publisher. Non è stata verificata qui la catena di fiducia Windows, l'appartenenza del file al catalogo o il caricamento con CI. |

Una whitepaper Parallels descrive storicamente framebuffer condivisi fra processo VM e GUI, con presentazione desktop/Coherence. È riferita a **Desktop12/Intel, copyright2016**: non la uso per attribuire quel preciso trasporto alla versione ARM64 corrente. [Whitepaper, pagina7](https://www.parallels.com/static/pl/fileadmin/res/doc/pdb/whitepaper/PDB_WP_Security_EN_LTR.pdf).

## Conseguenza per Perpendicular

La direzione da privilegiare è **un adattatore accelerato con più uscite**, poi un agente che mantenga geometria e finestre coerenti con il Mac. Il nostro schema N+1 può essere costruito sopra un supporto del genere, ma non è una funzione da copiare già dimostrata in Parallels.

Il blocco attuale è concreto: il nostro KMD ufficiale v0.4 dichiara `MAX_CHILDREN=1`; aumentare soltanto `max_outputs` sul lato host non gli insegna a esporre altre uscite. La prova alternativa con due adattatori misti ha perso l'accelerazione; il renderer3D corrente ha inoltre stato globale. Questi limiti restano quelli registrati in WIN-003, non vengono risolti dalla ricerca.

**Prossimo passo tecnico consigliato:** valutare l'estensione multischermo del driver aperto e del relativo protocollo, individuando subito un percorso di firma accettato da Secure Boot/CI. La prima milestone resta due uscite estese reali, accelerazione principale conservata e frame osservabile sulla seconda. Solo dopo: N+1, DPI e trasferimento finestra/dialogo. Non propongo di installare il driver Parallels sulla nostra VM: è legato al suo dispositivo e al suo protocollo, non è un driver VirtIO intercambiabile. Una compilazione locale test-signed non soddisfa il requisito finale.

Questa ricerca è completata; **TODO-001 resta BLOCCATO per l'implementazione protetta**, senza modifiche o nuove verifiche nel clone e nella main.

## Tracciabilità delle evidenze

Gli indirizzi sono virtual address dei file originali; nomi `FUN_…`, tipi e pseudocodice sono ricostruzioni Ghidra. Nessun codice decompilato o componente proprietario viene aggiunto al repository. Output completi conservati privatamente in `~/Library/Application Support/Perpendicular Research/Parallels-Multimonitor-20261025`; SDK precedente in `Perpendicular Research/REA/parallels-27.0.3-20261021.json`.

| Evidenza REA | Riferimento |
| --- | --- |
| Registrazione miniport `0x14002a000` | `ev_cfa27794787f68b6dabdd3a2fdf2adb067ee55a2292efd06beee04f70872925f` |
| StartDevice, conteggio per adattatore | `ev_80d43e4eedaf1240d72655d1f42585302e575bf74de40416541dc5a7ab22c193` |
| QueryChildRelations, identificativi delle uscite | `ev_c04a9d822c4cdec718360a0f5c2d6c17990c72a217f85d6e39ae2f90ebb5b030` |
| Importazioni frontend Mac corrente | `ev_746558b4d562f64fa7a1cd57a362c2059115b51b398c71144c5c5556e76bad2f` |
| SDK SetConfiguration, analisi precedente sullo stesso hash | `ev_d40b5df55ee781d96c45a6c6d6690aa25bc725ef6d23421c12a3005c284073fa` |
| SDK GetScreenSize / SyncSetScreenSurface | `ev_dc734089a158a683bd1c2ce04e64c1f521ab5aa4cff1c2f38011891d9ffd7624` / `ev_8ca0a8eb5ac7a7a4d5250a7057a747366b7b7becb9992ddb4b5ffa2a6622a932` |
| Coherence, eventi/canale e chiamata agli hook | `ev_4030fb4e8c18efa8e33516a6d83e2067b0b5ad2424b7d649a3d17dc06003707b` |
| Coherence, importazioni/manifest | `ev_d14c8f3699022753db52d4ca8a1f5b6a23f82247c960d40f29be3c9021b44c09` |

Identità SHA256:

- `prl_kmdd.sys_m`, miniport ARM64 estratto: `aa3a6e0a45659a207dce2980592bfea24694dcce6f93928f8703ebe517b9087f`.
- `coherence.exe`, ARM64: `11a542007e927a34596393854de57ff13f7a9693113cc66be2839eb6f201aea4`.
- `prl_client_app`: `8aafd57766594be4120607f69e795966cd5615f02d0cd79563e05b57ef49527f`.
- SDK universale: `3fc83b8938ede4fc5ed385c2dcdea949da7f5302f4491ed868df4be39c84ae2a`.
- Slice ARM64 dello SDK: `a7396393fb90cc3095cce5090431063456bd0b0b5c33711c20cf84878cb0862d`, identica al target REA del21 ottobre.

Estrazione: archivio `Resources/Tools/prl-tools-win.tar.gz` → `Data/ARM64/ParallelsTools-ARM64.msi` → CAB incorporato → soli membri selezionati. L'ISO ARM64 piccola contieneva il bootstrap e non il miniport: non era sufficiente. Identità, provenienza e limiti delle operazioni sono registrati anche nel [diario delle verifiche](../VERIFICATION.md#25-ottobre--parallels-multischermo-ricerca-rea-e-fonti-primarie).
