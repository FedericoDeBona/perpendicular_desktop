# Candidata Ethernet ARM64 — stato main del28ottobre2026

**Reconnect v4 verificato nella main:** utente conferma entrambe le connessioni e ciclo Connect→Disconnect→Connect, corroborato da quattro tunnel operativi e flag0/0. ADD-003 corretto nel perimetro osservato. Lo slot GetIfEntry specifico ora contiene TAP-Windows Adapter V9; istruzioni/driver/altri controlli invariati. Accesso Mac disponibile per treIP, rispostaHTTP20 verificata; qualità5000 e reset intermittenti restano ADD-004, causa non isolata. [Esito e limiti](../../docs/VERIFICATION.md#28-ottobre--linkmanager-reconnect-riuscito-e-confronto-http-macwindows).

**Installata sulla main93be6687: driver TAP9.27.0 ARM64 Running, servizio LinkManagerSvc Running, client x64 emulato in esecuzione e portale “LinkManager: Ready” dopo login/autorizzazione eseguiti dall'utente.** Nessun riavvio o modifica delle protezioni. Utente conferma accesso remoto e reconnect; pagine/operazioni complete, affidabilità generale e nuovo boot non qualificati.

La prima candidata, limitata ai12HardwareID, falliva con “Could not open or install LinkManager Adapter”. Nuova analisi REA del filtro0x140085400: verifica anche ProductName e ProviderName. Il preparatore ora adatta anche6slot dati delle alternative VirtualBox/Sun a TAP-Windows Adapter V9/TAP-Windows Provider V9, lasciando invariati i nomi Secomea e i controlli GUID/PnP. Il solo rename della scheda non bastava; la correzione v2 avvia il client/HTTP locale11445 con risposta200. Driver/INF/CAT invariati, nessuna istruzione eseguibile modificata.

Installazione locale protetta: `C:\ProgramData\Perpendicular\LinkManagerArm64-20261028`, input/output/hash in candidate.json e stato privato in driver-state.json; prima copia user-mode conservata in before-v2. Sola scheda posseduta rinominata LinkManager Adapter. Servizio auto registrato dal proprio -install; client avviato come utente normale con task temporaneo poi eliminato. Collegamento “LinkManager ARM64” nel menu Start. Nessun autoavvio del Tray aggiunto: il servizio automatico non equivale al riavvio del client utente. Non è il setup completo Secomea USB/seriale.

`driver-stage.ps1` è stato eseguito realmente in Windows PowerShell5.1 ARM64: parser/trust/installazione PASS. Apertura TAP e IOCTL GET_VERSION9.27.0, GET_MAC6byte, GET_MTU1500 PASS. Non provato SET_MEDIA_STATUS separatamente. `install-client.ps1` raccoglie la sequenza verificata di identità/nome scheda, servizio, collegamento e avvio limitato; **parser Windows PASS, intera invocazione dello script non ripetuta sulla sessione autenticata**. Nessuna disinstallazione/reinstallazione o prova clone eseguita. Registro e limiti in [VERIFICATION.md](../../docs/VERIFICATION.md#28-ottobre--linkmanager-installazione-protetta-e-portale-ready).

La preparazione corrente è in QA/linkmanager-20261028/candidate-v4-reconnect fuori Git; solo il Tray cambia rispetto alla v3, backup installato in before-v4-reconnect. Le cartelle iniziali sulla Scrivania conservano le versioni precedenti. I31record supplementari REA sono verificati dal verifier insieme ai31originari.

## Accesso dal Mac alla VPN Windows

**Aggiornamento operativo successivo:** prima implementazione [host-vpn](host-vpn/README.md) installata/attiva, TCP/UDP da socket Mac verso endpoint Windows sullo stesso IP verificati; configurazione finale per192.168.10.111/32, prova dispositivo remoto ancora rinviata. Interfaccia TUN Mac e relay cifrato sulla rete QEMU esistente, senza NIC aggiuntive/reboot/forwarding Windows. La descrizione di assenza del percorso nel paragrafo sotto è lo stato precedente, superato soltanto per questo incremento circoscritto. Altri IP, scoperta automatica, ICMP/L2 e persistenza al boot non qualificati.

Nuovo obiettivo dell'utente: raggiungere anche dal Mac lo stesso IP remoto, per esempio192.168.10.111. **Con il setup corrente non è disponibile:** QEMU attivo usa netdev user/NAT con il solo guestfwd Samba; Windows ha forwardingIPv4 disabilitato sulle due NIC. Le cartelle condivise non condividono il tunnel.

Per mantenere l'IP originale serve un percorso privato Mac→Windows, route host mirata al dispositivo, inoltro/NAT Windows→TAP e gestione del ritorno. È una strategia da implementare e verificare quando sarà disponibile il dispositivo, non una capacità qualificata dal Ready. Un'alternativa circoscritta è proxy/inoltro di singole porte sulla rete esistente, con indirizzo/porta locali e limiti di protocollo. Nessuna modifica route, NAT, rete VM o Samba eseguita per questa richiesta. Evitare di deviare l'intero traffico Internet Mac; rimuovere route alla disconnessione e valutare sovrapposizioni con la LAN locale. [Rete user-mode QEMU](https://www.qemu.org/docs/master/system/devices/net.html).

## Dettagli della preparazione iniziale (prima della verifica main)

I paragrafi sotto conservano i vincoli e la procedura offline; le indicazioni di mancata verifica descrivono il primo incremento e sono superate, soltanto nel perimetro indicato sopra, dalle prove main.

## Cosa è implementato

`prepare_candidate.py` prepara fuori dal repository tre copie x64 di LinkManager11.9 con selezione TAP adattata da `lmtap` a `tap0901` e identità OpenVPN accettata, insieme al driver OpenVPN9.27.0 ARM64 ufficiale. Il codice utente resta x64 e richiede l'emulazione Windows. Non è una conversione degli EXE ad ARM64.

Le dodici modifiche HardwareID occupano slot dati esistenti di12byte; le sei modifiche prodotto/produttore e il controllo della descrizione operativa slot di24byte, verificati negli input originali; nessuna istruzione o sezione eseguibile cambia. Tutti gli input hanno SHA256 fissato. La directory Authenticode è azzerata e il checksum PE aggiornato: **le copie sono modificate e non più firmate Secomea**. I byte dell'overlay originale sono conservati, ma la sua firma non viene presentata come firma della candidata. Originali nel repository invariati. Nessuna patch al SYS, INF o CAT.

`driver-stage.ps1` è la prima fase sperimentale dell'installer, limitata al driver: Inspect (predefinito, sola lettura), Install, Remove. Usa DevCon ARM64 incluso nel pacchetto ufficiale; verifica hash, trust Authenticode Windows di CAT/SYS e, prima di mutare, privilegi, Secure Boot e Code Integrity/TestSigning. Rifiuta schede TAP0901 già presenti, comprese quelle non collegate. Registra stato prima/dopo, route/DNS precedenti e l'istanza creata; Remove riguarda soltanto quella istanza. Nessun reboot automatico, modifica route/DNS, arresto servizi o esecuzione del setup LinkManager. Il pacchetto nel Driver Store è conservato dopo Remove, perciò non è ancora una disinstallazione completa. Stato e snapshot rete rimangono privati nella directory generata.

**Implementato e verificato offline:** preparatore, pin/hash, patch riproducibile, istruzioni eseguibili immutate, rifiuto di input alterati. **Implementato ma non eseguito/validato in Windows:** script driver-stage, inclusi trust, installazione e rimozione. PowerShell non disponibile su questo host: nessun parser Windows eseguito. Non usare questa fase come attestazione di caricamento del driver o installer completo.

## Preparazione riproducibile

Python3.9+ con sola libreria standard; nessun programma Windows eseguito. Scaricare lo [ZIP ufficiale9.27.0](https://github.com/OpenVPN/tap-windows6/releases/download/9.27.0/dist.win10.zip), poi dalla radice del progetto:

```sh
python3 addons/linkmanager-arm64/verify_evidence.py
python3 addons/linkmanager-arm64/test_candidate.py
python3 addons/linkmanager-arm64/prepare_candidate.py \
  --tap-archive /percorso/dist.win10.zip \
  --output /percorso/esterno/al/repository/nuova-candidata
```

L'output deve essere una directory nuova fuori dal repository; un output esistente viene rifiutato. Il download non è automatico. `candidate.json` descrive input/output, offset, hash e limiti. Non aggiungere output o pacchetto driver al Git: gli input LinkManager già conservati rimangono la sola eccezione autorizzata precedente. Distribuzione dei componenti Secomea modificati e obblighi GPL del driver richiedono una decisione separata; per ora il generatore produce una copia sperimentale locale.

In un successivo contesto Windows ARM64 identificato e libero dal lavoro concorrente, la fase driver si usa da PowerShell7 ARM64 nativo, dapprima `./driver-stage.ps1 -Mode Inspect`. Install/Remove richiedono elevazione. Lo script e il manifesto devono rimanere insieme alla directory driver-arm64. Non avviare ancora gli EXE modificati come sostituti dell'installazione ordinaria.

## Mappa dei confronti HardwareID

Tutti sono confronti `_stricmp` su HardwareID. Creazione confronta il driver disponibile; le altre operazioni confrontano la scheda e verificano anche l'identità PnP ricavata dal GUID richiesto. L'alternativa `vboxtap` resta invariata. La patch non introduce selezione per nome visualizzato o rimozione globale TAP.

| Binario | Creazione | Rimozione | Abilitazione | Disabilitazione |
| --- | --- | --- | --- | --- |
| LinkManagerSvc | 0x140003020 | 0x1400040b0 | 0x140004830 | 0x140005170 |
| LinkManagerTray | 0x140085930 | 0x1400869c0 | 0x140087140 | 0x140087a80 |
| tapmgr | 0x140004830 | 0x1400058c0 | 0x140006040 | 0x140006980 |

[Nuove evidenze REA](evidence/arm64/) conservano xref e pseudocodice delle funzioni mancanti; creazione Svc e rimozione Tray erano già documentate in [evidence/decompilation.md](evidence/decompilation.md). Questa mappa copre i12slot ASCII `lmtap` degli input fissati, non dimostra assenza di chiamate indirette o contratti ulteriori.

## Driver scelto e firma

Candidata sperimentale: [release TAP9.27.0](https://github.com/OpenVPN/tap-windows6/releases/tag/9.27.0), pubblicata19marzo2024; API GitHub latest consultata28ottobre2026. ZIP SHA256 `36e2609b7ceefedcb978ce5c48caf9e0e5af83423717c4e2e3c1d7ebca8f62a5`. Membri ARM64 e hash fissati nel generatore.

INF: NTARM64, HardwareID `tap0901` e `root\tap0901`, servizio tap0901, DriverVer02/27/2024,9.27.0.0. SYS e DevCon PE Machine0xaa64. CAT e firma SYS contengono un certificato Microsoft Windows Hardware Compatibility Publisher; **il trust, l'appartenenza al catalogo e il caricamento protetto non sono verificati su Windows**. Il tentativo locale LibreSSL `cms -verify -noverify` fallisce nel parsing ASN.1: non è una validazione crittografica positiva né dimostra firma non valida.

[Header alla tag9.27.0](https://github.com/OpenVPN/tap-windows6/blob/9.27.0/src/tap-windows.h), [dispatch](https://github.com/OpenVPN/tap-windows6/blob/9.27.0/src/device.c) e [version.m4](https://github.com/OpenVPN/tap-windows6/blob/9.27.0/version.m4) sono coerenti staticamente con apertura `\\.\Global\<GUID>.tap`, ReadFile/WriteFile OVERLAPPED e i quattro IOCTL già osservati. Major9 evita il ramo legacy0x22002c; comportamento runtime ancora da misurare. [Licenza GPLv2 e WDK exception](https://github.com/OpenVPN/tap-windows6/blob/9.27.0/COPYING): conservare pacchetto e sorgenti corrispondenti secondo le condizioni in caso di distribuzione.

## Prossimo incremento concreto

1. Validare parser/script, trust Windows, installazione/rimozione del solo driver e apertura TAP (versione/MAC/MTU/media) in un contesto separato dal lavoro Samba. Nessuna ricreazione automatica dei vecchi clone.
2. Risolvere il lifecycle dalle chiamate SetupDi in servizio/Tray/helper x64 emulati. Non è dimostrato che il solo cambio HardwareID basti; il DevCon nativo gestisce soltanto il primo install. Se emergono errori d'architettura, serve delegare le operazioni interessate a helper ARM64 con il contratto effettivo del chiamante.
3. Completare estrazione/installazione dei soli componenti user-mode, registrazione servizio e richiamo browser conservando risorse/dipendenze del setup originale; il solo trio di EXE non è presentato come installazione completa.
4. Soltanto quando disponibili le credenziali, apertura portale→riconoscimento LinkManager→login/Connect/Disconnect/reconnect. Una lettura remota riconoscibile sarà necessaria per qualificare Ethernet end-to-end, senza richiederla per continuare ora.

Nessuna installazione, prova clone o verifica main eseguita in questo incremento. USB/seriale fuori dal primo percorso. TODO-024 resta IN CORSO; diario delle verifiche nel registro principale del progetto.

## Diagnostica di una connessione

ADD-003 è corretto nel ciclo reconnect verificato con la candidata v4; ADD-004 conserva i problemi di qualità ancora da isolare; la sospensione iniziale è superata dalla ripresa autorizzata. Il dettaglio e il criterio di chiusura sono nel diario collegato sopra. `collect-debug.ps1` salva il debug già esposto dal client locale e gli eventi applicativi pertinenti nella directory privata Diagnostics dell'installazione Windows; senza argomenti esegue un solo campione, `-DurationSeconds 180` raccoglie per tre minuti. Nessun login/Connect o modifica livello debug. I file possono contenere dettagli della sessione e restano fuori Git. [Procedura ufficiale Secomea](https://kb.secomea.com/docs/how-to-collect-linkmanager-debug-log); [esiti e limiti](../../docs/VERIFICATION.md#28-ottobre--diagnosi-errore-linkmanager-e-prove-sospese). Non confondere un debug fresco di avvio con il log di un tentativo precedente non conservato.
