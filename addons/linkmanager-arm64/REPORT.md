# LinkManager 11.9 su Windows ARM64 — analisi e piano operativo

Data: 27 ottobre 2026. Attività principale: [TODO-024](../../docs/TODO.md#todo-024--addon-linkmanager-su-windows-arm64). [Diario delle verifiche](../../docs/VERIFICATION.md#27-ottobre--linkmanager-arm64-analisi-rea-e-piano-addon).

**Stato: studio statico completato nel perimetro descritto; soluzione non implementata.** Nessuna installazione, esecuzione dei programmi Windows, compilazione di driver, modifica della VM o qualifica nell'app principale. Questa cartella contiene un dossier per un addon futuro: non esiste ancora un sistema plugin o un addon installabile.

## 1. Risultato richiesto e primo traguardo

L'utente chiede di studiare se l'installer/driver LinkManager possa funzionare nella VM Windows ARM64 del progetto e di documentare il percorso verso una soluzione utilizzabile. L'autorizzazione attuale riguarda ricerca e documentazione; non avvia automaticamente i futuri interventi Windows elencati sotto.

**Primo traguardo proposto: accesso Ethernet reale.** Dalla VM ARM64, aprire LinkManager, autenticarsi sul GateManager autorizzato, collegare un agente Ethernet e usare il programma Windows di destinazione per leggere un dato identificabile dal dispositivo remoto. Dopo disconnessione e riconnessione, ripetere quella lettura. Il dispositivo, il programma, il protocollo e l'operazione vanno scelti prima della prova: il solo login, un ping o una scheda presente in Gestione dispositivi non soddisfano il criterio.

L'uso di un'operazione di sola lettura è il criterio proposto per la prima verifica, non un requisito già concordato per tutte le funzioni future. USB, seriale, discovery e livello 2 restano capacità separate da qualificare quando richieste. Non promettere equivalenza completa con LinkManager su Intel a partire dal solo accesso TCP.

## 2. Esito tecnico

| Domanda | Risposta attuale | Evidenza / limite |
| --- | --- | --- |
| Il pacchetto originale contiene driver ARM64? | No nella ricognizione dei payload x86/x64 esaminati. | PE dei driver Intel; INF senza sezioni ARM64. |
| Avviare l'installer può rendere utilizzabili quei driver su ARM64? | No: i driver kernel inclusi non sono emulabili da Windows ARM. | Vincolo della piattaforma, non un problema risolvibile con il solo bootstrap. |
| Applicazione e servizio x64 devono necessariamente essere riscritti? | Non dimostrato. L'emulazione del codice utente rende plausibile conservarli. | Avvio e funzionamento su ARM64 non provati; helper e SetupDi da verificare. |
| La parte rete usa un contratto totalmente proprietario? | I percorsi decompilati usano il dispositivo e comandi standard TAP. | Non è una prova di equivalenza di tutto il driver o di tutti i percorsi. |
| Basta installare OpenVPN ARM64? | Non dimostrato, e il riconoscimento specifico del driver è un ostacolo concreto. | Il codice confronta HardwareID come `lmtap`; alcune routine ammettono anche `vboxtap`. |
| È credibile un adattamento Ethernet? | Sì, come ipotesi tecnica sostenuta dal confine TAP osservato. | Servono implementazione, firma valida, installazione e prova end-to-end. |
| USB e seriale funzionerebbero con lo stesso intervento? | Non stabilito. | Dipendono da driver e contratti differenti, non decompilati in questa passata. |

Windows 11 ARM emula applicazioni x86/x64, ma richiede driver kernel compilati per ARM64: [Microsoft, funzionamento dell'emulazione](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation). Il progetto [TAP-Windows6](https://github.com/OpenVPN/tap-windows6) supporta ARM64 e indica NDIS 6.30 per tale piattaforma. Questo supporto upstream non prova l'intercambiabilità del pacchetto generico con la variante Secomea.

## 3. Materiale esaminato e riproducibilità

Installer fornito: `v6051_11.9.626364010_LinkManager_Setup.exe`, presente nei Download del Mac durante l'analisi.

SHA-256 originale: `e8cf6131dd37d91bcda35a2de7f61f910c62be0bddf5d8a91ecb0dd82a01f03c`.

Il bootstrap è un PE x86/NSIS e contiene due installer: `$PROGRAMFILES64/LinkManager-x64-setup.exe` e `$PROGRAMFILES/LinkManager-x86-setup.exe`. La seconda passata REA si concentra sul payload x64; il contenitore originale è rimasto invariato, verificato mediante SHA-256 al termine.

SHA-256 installer interno x64: `b872e377cf5908794f2d76106d31039f256f48282aa7e37af7a773da1e8c6202`.

| File derivato | Byte | SHA-256 | Seconda passata |
| --- | ---: | --- | --- |
| `LinkManagerTray.exe` | 1139640 | `0d78ccee781d9e5b0b85ee805fb4a30f1170d6c0e7080a3de4f6f13c236e45bb` | Decompilato con REA/Ghidra. |
| `LinkManagerSvc.exe` | 176056 | `ea2ee69df1e26c4d4d5eba405b2426216632737c287c132e2a50bc4613786d90` | Decompilato con REA/Ghidra. |
| `lmtap.sys` | 54296 | `734d78c959b1348d41d24ce2d86b023b7a6f469cb0d379ecfc2ccfce879261e6` | Una variante x64 decompilata. |
| `tapmgr.exe` | 142848 | `a3315c2123e8ebc510d540b752ab356c6b5eeff0034c531d3454a5b0a6a0e130` | Estratto e identificato; non decompilato separatamente. |

Strumenti: REA 6.5.0, Ghidra 12.1.4, Java 21.0.12.1 su macOS ARM64. Il recupero dei payload NSIS è stato effettuato con 7-Zip e Python/lzma; non attribuirlo a REA. La decompressione del flusso solid è stata percorsa per blocchi con lunghezza a 32 bit; `provenance.json` conserva gli offset dei file derivati, che non sono offset nell'EXE originale. I file sono stati poi importati da REA in progetti Ghidra temporanei, chiusi al termine.

La prima ricognizione dei due payload aveva individuato `lmtap.sys` (rete), `com0com.sys` (seriale) e `USBIPEnum.sys` (USB), tutti in varianti Intel, senza sezioni ARM64 negli INF esaminati. Alcuni componenti sono presenti in più versioni: prima di una futura installazione individuare esattamente la variante selezionata dal setup. La decompilazione di una copia di `lmtap.sys` non qualifica automaticamente tutte le copie.

Le evidenze grezze, i manifesti e il report iniziale sono conservati **fuori dal repository** in:

```text
~/Library/Application Support/REA/Investigations/linkmanager-11.9-arm64-20261027/
    provenance.json
    evidence-index.json
    report.md
    NNN-tools-call.json   (31 record REA completi)
```

Gli hash e gli ID riportati qui consentono di riconoscere i materiali anche su un altro Mac. La cartella privata non viene distribuita con Git; il dossier rimane leggibile senza di essa. I binari estratti erano in una cartella temporanea e possono essere ricavati di nuovo dall'installer con hash corrispondente. Non aggiungere EXE/SYS, certificati, credenziali, dischi o dump privati al repository.

## 4. Risultati della decompilazione

### Riconoscimento e creazione della scheda

Nel servizio, `FUN_140003020` enumera i driver tramite SetupDi e confronta il loro HardwareID con `lmtap`; se non trova una corrispondenza, prepara l'errore che chiede di reinstallare il driver LinkManager. La stessa funzione usa SetupDi per creare/installare il dispositivo e legge `NetCfgInstanceId`.

Nel Tray, `FUN_1400869c0` è una routine di rimozione: enumera le proprietà HardwareID, ammette `lmtap` o `vboxtap`, confronta l'identità PnP e rimuove il dispositivo selezionato. L'accettazione di `vboxtap` in questa routine non dimostra che venga accettato in ogni percorso di creazione, selezione o collegamento.

**Conseguenza:** rinominare la scheda nel pannello di rete non risolve il riconoscimento. Occorre una mappa completa dei confronti in Tray, servizio e helper; non cambiare alla cieca le stringhe o le proprietà del registro.

### Apertura e scambio dei pacchetti

`FUN_1400967f0` nel Tray costruisce `\\.\Global\<GUID>.tap` e lo apre in lettura/scrittura con I/O OVERLAPPED. `FUN_1400964e0` invia dati con WriteFile e attende l'eventuale completamento; `FUN_1400965e0` usa ReadFile/GetOverlappedResult. `FUN_140095e70` abilita e disabilita il collegamento con `0x220018` e un intero da quattro byte.

Nelle funzioni di controllo `FUN_140005a50` del servizio e `FUN_140088360` del Tray, il programma apre il dispositivo TAP e richiede `0x220008`, con un buffer versione di 12 byte. Chiama `0x22002c` soltanto se la major restituita è minore di 9. Il driver esaminato restituisce major 9, minor 23, evitando quel ramo.

**Attenzione al ramo legacy:** nell'header OpenVPN corrente `0x22002c` significa PRIORITY_BEHAVIOR. Non assumere che il suo uso storico Secomea abbia la stessa semantica. Una candidata con major almeno 9 evita quel ramo osservato, ma deve comunque essere qualificata.

### Confine esposto dal driver

Nel `lmtap.sys` x64 identificato sopra, `FUN_14000a360` gestisce:

| Codice | Contratto TAP corrispondente | Comportamento osservato |
| --- | --- | --- |
| `0x220004` | GET_MAC | Restituisce sei byte. |
| `0x220008` | GET_VERSION | Restituisce tre interi da 32 bit: 9, 23, 0. |
| `0x22000c` | GET_MTU | Restituisce un intero da 32 bit. |
| `0x220018` | SET_MEDIA_STATUS | Accetta un intero da quattro byte, modifica lo stato del collegamento. |

Gli altri codici nel dispatch esaminato finiscono nel ramo INVALID_DEVICE_REQUEST. Nomi, numeri e percorso sono confrontati con l'[header TAP upstream](https://github.com/OpenVPN/tap-windows6/blob/master/src/tap-windows.h) e con [device.c](https://github.com/OpenVPN/tap-windows6/blob/master/src/device.c). Il sorgente upstream corrente è un riferimento di confronto, non il sorgente autenticato della variante Secomea.

Dei quattro chiamanti diretti di DeviceIoControl recuperati nel Tray, due riguardano TAP e due la comunicazione seriale. Questo non esclude chiamate indirette o altri percorsi non risolti.

### USB, seriale e disponibilità dei sorgenti

La pagina delle licenze incorporata dichiara TAP-Windows, com0com e USB/IP per Windows e indica la disponibilità dei moduli GPL su richiesta al rivenditore. Non sono stati richiesti o ottenuti i sorgenti Secomea. Eventuali sorgenti corrispondenti sarebbero preferibili a deduzioni sui soli binari.

`com0com.sys` e `USBIPEnum.sys` non sono stati decompilati nella seconda passata. Non è dimostrato che un progetto moderno con lo stesso nome di protocollo o funzione possa sostituirli. USB remoto richiede inoltre la verifica del driver ARM64 del dispositivo finale, non soltanto del controller USB/IP virtuale.

## 5. Decisione di implementazione da prendere

Ordine proposto: verificare prima una strada con driver ARM64 già firmato e codice utente adattato, oppure un pacchetto Secomea ARM64 ufficiale se effettivamente disponibile. Se questa strada non è praticabile, valutare una variante del driver con identità `lmtap` a partire da sorgenti corrispondenti, indicando prima come produrre un pacchetto accettato dal Windows protetto del progetto.

| Strategia candidata | Vantaggio | Ostacolo da risolvere prima di adottarla |
| --- | --- | --- |
| Pacchetto Secomea ARM64 ufficiale | Contratti, aggiornamenti e firma gestiti dal produttore. | Non trovato nel pacchetto esaminato; disponibilità attuale da verificare, senza presumere che esista. |
| TAP ARM64 già firmato + adattamento mirato del codice utente | Riusa un driver nativo e può conservare le protezioni kernel. | HardwareID, helper, lifecycle e comportamento vanno adattati; cambiare un EXE firmato ne invalida la firma originale. Licenze e distribuzione vanno valutate. |
| Variante TAP ARM64 con identità Secomea | Può mantenere il contratto atteso dal programma originale. | Sorgenti/versione, modifiche, build e soprattutto firma valida del pacchetto sono prerequisiti concreti. |

Non è ancora stata scelta né implementata una strategia. Un livello di compatibilità nel codice utente è un'eventuale scelta da motivare, non un'architettura già stabilita. Evitare un framework plugin generico per questo singolo addon.

I vincoli protetti del progetto restano: Secure Boot e Code Integrity attivi, TESTSIGNING disattivato nella VM ordinaria. La precedente eccezione documentata per il multimonitor non autorizza un'eccezione per LinkManager. Modificare un INF o rinominare un SYS non converte l'architettura e non conserva automaticamente la validità del pacchetto firmato. Non occorre cambiare il meccanismo RAM, la grafica, virtiofs o il runtime QEMU per il solo adattamento TAP, salvo un diverso problema dimostrato.

## 6. Piano delle attività

Le attività sono un piano futuro. Gli ID LM appartengono a TODO-024; lo stato generale resta nella TODO del progetto. Per ogni passaggio registrare hash/versioni, risultato, errore se presente e prossima azione nel diario esistente, senza creare un secondo registro concorrente dei difetti.

| ID | Priorità e dipendenza | Stato | Risultato osservabile / verifica minima |
| --- | --- | --- | --- |
| LM-001 | P0, concluso prima dello sviluppo | FATTO, solo studio statico | Analisi con REA/Ghidra di servizio, Tray e una variante del driver; hash, indirizzi, limiti e ID disponibili nelle sezioni 3–4 e 8. Evidenza nel diario; nessuna qualifica runtime. |
| LM-002 | P0, primo passo operativo | DA FARE | Definire programma Windows, dispositivo, agente, protocollo TCP/UDP/L2 e operazione osservabile; verificare accesso/licenza e disponibilità di un target di prova. Senza target il successo end-to-end non è misurabile: dichiarare il limite, non sostituirlo con un ping. |
| LM-003 | P0, con LM-002 | DA FARE | Congelare i materiali: versione installer, hash delle copie effettivamente usate, INF/cataloghi e candidato ARM64. Identificare quale variante sceglie il setup e conservare una ricetta di estrazione ripetibile. Verifica: due estrazioni dei soli file necessari hanno gli stessi hash, se si implementa la ricetta. |
| LM-004 | P0, dipende da LM-003 | DA FARE | Completare la mappa statica dei confronti HardwareID e delle operazioni necessarie in Tray, servizio e tapmgr, incluse le quattro stringhe `lmtap` già trovate. Verifica: tabella indirizzo→creazione/selezione/rimozione/apertura, controlli versione ed eventuali chiamate indirette ancora irrisolte. Non decompilare indiscriminatamente tutto il prodotto. |
| LM-005 | P0, dipende da LM-004 | DA FARE | Scegliere una delle strategie della sezione 5 e risolvere provenienza/licenza/firma. Verifica: pacchetto ARM64 candidato identificato e percorso concreto per usarlo su Windows protetto; oppure ostacolo preciso con alternativa e condizione di sblocco. Non compilare ripetutamente un driver senza percorso di firma utilizzabile. |
| LM-006 | P0, prima di modificare Windows | DA FARE | Concordare il contesto di prova e un ripristino coerente. Non ricreare automaticamente i vecchi clone eliminati. Se si usa una copia isolata, identificarla come tale; se si lavora sulla principale, mantenerne esplicito il perimetro autorizzato. Registrare OS ARM64/build, NIC, route/DNS, servizi e protezioni prima dell'intervento, senza credenziali nei log. |
| LM-007 | P0, dipende da LM-005/006 | DA FARE | Primo percorso driver minimo: pacchetto ARM64 accettato, dispositivo sano, apertura del TAP e lettura versione/MAC/MTU; cambio media senza errore. Verifica nel contesto isolato scelto con Code Integrity/Secure Boot invariati. Un piccolo probe temporaneo è giustificato solo per distinguere un problema del driver da quello del programma; non equivale al traguardo Ethernet. |
| LM-008 | P0, dipende da LM-007 | DA FARE | Adattamento minimo della selezione del dispositivo e degli helper, secondo LM-005. Verifica: il LinkManager reale avvia servizio/app, seleziona la NIC candidata, apre il TAP e non fallisce nelle chiamate SetupDi da processo emulato. Registrare gli eventuali errori di architettura invece di attribuirli genericamente al driver. |
| LM-009 | P0, dipende da LM-002/008 | DA FARE | Prova completa Ethernet: login GateManager→Connect agente→lettura riconoscibile nel programma Windows→Disconnect→nuovo Connect→stessa lettura. Registrare endpoint/operazione in modo non sensibile, risultato e percorso effettivo. Qualificare UDP/discovery/L2 soltanto se necessari al caso scelto. È il primo criterio di “utilizzabile”. |
| LM-010 | P1, dopo LM-009 | DA FARE | Rendere installazione e rimozione ripetibili: manifesto versioni/hash, avvio del servizio, creazione della sola NIC addon, errori comprensibili, ripristino e disinstallazione. Verifica breve: installazione→collegamento→rimozione, rete ordinaria ancora funzionante e nessuna credenziale/policy di test lasciata dal pacchetto. Le patch/sorgenti possono stare qui, binari e dati privati restano esterni. |
| LM-011 | P1, dipende da LM-009/010 | DA FARE | Verifica nell'app principale, separata da quella isolata: stesso programma utente, accesso reale e contenuto osservato; poi un riavvio ordinario autorizzato e nuova connessione. Accertare recupero del servizio/NIC e assenza di route/DNS residui. Un riavvio riuscito non chiude l'affidabilità generale e non autorizza spegnimenti forzati. |
| LM-012 | P2, solo se richiesto dal caso d'uso | DA FARE, fuori dal primo traguardo | Seriali: contratti com0com e impostazioni/modem, poi una lettura reale. USB: compatibilità USB/IP Secomea, controller ARM64 e driver ARM64 del dispositivo finale, poi attach/uso/detach. Ciascuna capacità ha esito proprio; il fallimento USB non annulla un Ethernet già qualificato. |

### Come evitare tentativi senza progresso

Per ogni ostacolo usare una sola prova mirata che separi le cause: firma/caricamento driver, identificazione della scheda, apertura e comandi, traffico, instradamento o applicazione remota. Ripetere soltanto dopo una modifica pertinente o un nuovo dato. Se una strada non produce un incremento utilizzabile, annotare causa e perimetro, conservare la base funzionante e passare alla successiva strategia concreta. Nessun benchmark esteso prima del primo collegamento utile.

Se manca un driver firmato adatto, manca la possibilità di adattare legalmente/distribuire i componenti, oppure non sono disponibili sorgenti o account necessari, indicare esattamente cosa manca e cosa cambierebbe l'esito. Non dichiarare impossibile tutto LinkManager su ARM64 sulla sola base di uno di questi blocchi. L'impossibilità già stabilita riguarda soltanto il caricamento invariato degli attuali driver Intel nel kernel ARM64.

## 7. Criteri di completamento e stato delle verifiche

| Livello | Criterio | Stato al 27 ottobre |
| --- | --- | --- |
| Studio e piano | Conclusioni sostenute da evidenze, limiti espliciti e attività con risultato misurabile. | FATTO nel perimetro documentale, [diario](../../docs/VERIFICATION.md#27-ottobre--linkmanager-arm64-analisi-rea-e-piano-addon). |
| Implementazione candidata | Strategia scelta, driver/helper/adattamento e installazione minima disponibili. | DA FARE. Nessun codice addon scritto. |
| Verifica nel clone / ambiente isolato | LM-007/008/009 riescono con protezioni conservate su VM identificata. | NON ESEGUITA. Nessun clone creato per questa ricerca. |
| Verifica nell'app principale | LM-011 riesce nel prodotto e nella VM ordinaria effettivamente usati dall'utente. | NON ESEGUITA. Nessuna distribuzione. |
| Prima versione Ethernet utilizzabile | Collegamento applicativo reale, disconnessione/riconnessione, avvio ordinario e rimozione/ripristino qualificati per il caso dichiarato. | DA FARE; non copre automaticamente altri protocolli o impianti. |
| Parità completa | Ethernet richiesto, eventuali discovery/L2, seriale e USB tutti qualificati con dispositivi/driver effettivi. | NON DIMOSTRATA; requisiti ulteriori da definire. |

Nel diario distinguere sempre implementazione, ambiente isolato e app principale. Non segnare TODO-024 FATTO per il solo caricamento del driver. Non confondere lo studio del ramo di codice con l'esecuzione del ramo nella VM.

## 8. Indice delle evidenze REA principali

Il file indicato è nella cartella privata della sezione 3. I JSON contengono record completi con target/hash, profilo Ghidra e limiti; gli ID non sono URL di servizi esterni.

| Osservazione | File / funzione | ID evidenza |
| --- | --- | --- |
| Creazione NIC e HardwareID `lmtap` | `011-tools-call.json`, servizio `0x140003020` | `ev_fec94c9135ca5c7cbf67b6c550d2245c11409f4f5c16936f6a2f7822f0cacc56` |
| Apertura TAP e controllo versione nel servizio | `012-tools-call.json`, `0x140005a50` | `ev_c6885e5f90584f04ce7819489258e5ec07856f4ab5782872f926f645f13e2856` |
| Quattro chiamanti diretti DeviceIoControl nel Tray | `017-tools-call.json` | `ev_53c0e01ba05583e08f25f379123b794bcdf5f5bc479d2061818297b1fe07210c` |
| Apertura TAP e controllo versione nel Tray | `019-tools-call.json`, `0x140088360` | `ev_5be40ab74e7bd5ae004617a3d21c2677ef733bb3ab03585b73d8f7f62ebe10d3` |
| Attivazione/disattivazione media | `022-tools-call.json`, Tray `0x140095e70` | `ev_e5927989f223ee42152eacc6c9a488bdc51f60962caf66092708f0fe268407a6` |
| Scrittura pacchetti | `024-tools-call.json`, Tray `0x1400964e0` | `ev_2891ef5791c3ff6675f46f1bcb08473722feba50411f6c88fc9a1249c68aea98` |
| Lettura pacchetti | `025-tools-call.json`, Tray `0x1400965e0` | `ev_6572e59f63feb78090a9175e2ff1aba93f191c7d7f75234cbe987edcee3d18ed` |
| Percorso dispositivo standard TAP | `029-tools-call.json`, Tray `0x1400967f0` | `ev_3352ace05ac070709a376c41a70d5c9a5b09f0b4471f5483d2a20d311ee5a9ba` |
| Rimozione con HardwareID `lmtap`/`vboxtap` | `030-tools-call.json`, Tray `0x1400869c0` | `ev_297afdd0ac24cad7f3fdf2717f6065a453dece4b243f1c9309bab381086f2322` |
| Dispatch dei quattro comandi nel driver | `038-tools-call.json`, `lmtap.sys` `0x14000a360` | `ev_9cfb91e9b07bbaf1d997d4c3906f154f41de91a55a6d4dcabd622b751877c4da` |

## 9. Limiti e tentativi non riusciti

La prima analisi non poté usare REA perché mancavano i moduli dell'installazione locale; usò inventario/decompressione e documentazione. Ripristinato `rea-agents` 6.5.0 dal lockfile esistente, verificati avvio MCP, 207 strumenti e disponibilità Ghidra. Nella seconda passata l'accesso tramite Node REPL ha incontrato problemi di caricamento modulo e `Event` assente; l'analisi effettiva è stata svolta tramite una sessione MCP REA locale con client Python. La prima ricerca del nome non qualificato `DeviceIoControl` non ha trovato il simbolo; quella qualificata `KERNEL32.DLL::DeviceIoControl` ha risolto i chiamanti. Questi esiti non sono errori di LinkManager.

Lo pseudocodice è una ricostruzione: Ghidra segnala sostituzioni dei controlli stack/cookie, blocchi rimossi e globali sovrapposti; nel driver alcuni dettagli dello stack e dei tipi sono imperfetti. Le osservazioni sono limitate alle chiamate, costanti e confronti descritti. La ricerca delle stringhe vede i dati riconosciuti da Ghidra: l'assenza di una stringa non dimostra l'assenza di una funzione. Le chiamate indirette irrisolte non sono state dichiarate inesistenti.

Non sono stati verificati runtime, firme secondo le policy del Windows target, protocollo GateManager end-to-end, helper su ARM64, sorgenti Secomea, USB o seriale. Nessuna prestazione, stabilità generale o compatibilità con tutti gli impianti è stata misurata. Gli aggiornamenti futuri del produttore richiedono un nuovo confronto degli artefatti prima di riusare conclusioni basate su questa versione.
