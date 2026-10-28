# Prima candidata Ethernet ARM64 — 28 ottobre 2026

Il percorso utente è **aprire https://gm5.gate-manager.it/lm e lasciare che il portale richiami LinkManager**. La preparazione procede senza credenziali; login e connessione reale restano verifiche successive. Non occorre conoscere ora programma/dispositivo industriale per completare la preparazione locale.

## Cosa è implementato

`prepare_candidate.py` prepara fuori dal repository tre copie x64 di LinkManager11.9 con selezione TAP adattata da `lmtap` a `tap0901`, insieme al driver OpenVPN9.27.0 ARM64 ufficiale. Il codice utente resta x64 e richiede l'emulazione Windows. Non è una conversione degli EXE ad ARM64.

Le dodici modifiche occupano slot dati esistenti di12byte, verificati negli input originali; nessuna istruzione o sezione eseguibile cambia. Tutti gli input hanno SHA256 fissato. La directory Authenticode è azzerata e il checksum PE aggiornato: **le copie sono modificate e non più firmate Secomea**. I byte dell'overlay originale sono conservati, ma la sua firma non viene presentata come firma della candidata. Originali nel repository invariati. Nessuna patch al SYS, INF o CAT.

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
