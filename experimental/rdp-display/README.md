# Prova circoscritta del display RDP

Candidato da verificare, escluso dalla build ordinaria. Usa FreeRDP tramite API C; l'interfaccia Mac resta Swift/AppKit/Metal e il guest resta Rust. RDPEDISP può offrire monitor e scala senza il nostro driver 3D, ma richiede una sessione RDP autenticata: non modifica semplicemente il display della console.

`build-freerdp.sh` verifica l'archivio ufficiale fissato nel manifest e prepara librerie ARM64 in `.build/FreeRDP`. Richiede CMake e OpenSSL@3 già presenti. Non installa dipendenze o apre connessioni. Sono esclusi client X11/SDL, server e canali di redirezione; licenza e provenienza restano nel prefisso privato. Le dipendenze OpenSSL usano ancora il percorso Homebrew: non è un pacchetto distribuibile.

`build-probe.sh` compila l'adapter C ed esegue soltanto `--self-check`, senza rete. La modalità di connessione accetta esclusivamente loopback, NLA e un pin SHA256 obbligatorio del certificato. Il helper riceve credenziali e pin da pipe in memoria; non passare mai password attraverso argomenti, ambiente, comandi della shell o file.

`build-connect.sh` prepara `.build/FreeRDP/DisplayConnect.app`, una piccola UI Swift 6/AppKit separata dall'app ordinaria, firmata ad hoc. Non la avvia. Accetta `--helper`, `--username`, `--port`, `--width`, `--height`, `--scale` e `--pin-sha256` come argomenti pubblici. Il pin deve essere quello del certificato letto e verificato indipendentemente nella sola copia Windows. La password si inserisce esclusivamente nel campo sicuro della UI: account e password non vengono salvati o stampati. Il campo viene svuotato dopo aver preparato i tre record per la pipe, che viene chiusa subito dopo la scrittura. Il buffer mutabile viene azzerato; non si presume che Swift/AppKit garantiscano la cancellazione di ogni copia temporanea in memoria.

La UI avvia soltanto il helper indicato con un ambiente esplicitamente limitato, mostra solo stati riconosciuti e geometria, e termina il proprio helper su annullamento o chiusura. La durata del probe è fissata a 60 secondi, compresa la connessione; la UI ne forza l'uscita entro circa 65 secondi. Non arresta la VM né altre app. Un processo terminato prima della fine può lasciare aperta la sessione Windows, recuperabile dalla console.

Il probe attende le capacità `disp`, invia un solo layout entro i limiti annunciati e si disconnette dopo la prova. Mantiene l'output del server consentito e disabilita la sola decodifica locale. Distingue layout inviato e dimensione osservata: nessuno dei due sostituisce la lettura effettiva di monitor e DPI nel guest.

Verificato: build delle librerie, dipendenze, creazione e configurazione del context, compilazione Swift 6 e firma ad hoc della UI. La UI non è stata avviata durante la preparazione. **Nessuna connessione RDP reale eseguita in questo passaggio.** Restano da verificare WGC, popup, input, selezione della sessione utente, DPI e riconnessione. L'utente ha autorizzato la prova RDP esclusivamente sulla copia Windows, con accesso loopback dal Mac, NLA e certificato verificato. La build di questi helper non abilita RDP né modifica la VM. Non modificare password, NLA, Secure Boot o regole per password vuote.

Fonti primarie: [FreeRDP 3.32.2](https://github.com/FreeRDP/FreeRDP/tree/3.32.2), [MS-RDPEDISP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/bdc90b21-4b14-43bc-9c03-b7fecbfc6a1f), [sessione console](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-wtsgetactiveconsolesessionid).


## Preparazione effettiva della copia

L'utente ha autorizzato la prova nella sola copia Windows. `bootstrap-guest.py --remote-display-setup` prepara lo script locale `setup-remote-display.ps1`: conserva i valori originali, abilita NLA/TLS e una sola regola TCP3389 limitata a 10.0.2.2. `-Undo` ripristina lo stato salvato. Il port forwarding temporaneo QEMU è esclusivamente su 127.0.0.1; non fa parte della configurazione ordinaria.

Il worker offre `rdp_info`, inventario nativo in sola lettura di sessione, impostazioni e certificato pubblico: nessuna chiave privata o password viene letta. La configurazione del servizio conserva `ownerSid`; il supervisore sceglie solo l'unica sessione attiva di quell'utente. Configurazioni precedenti senza ownerSid mantengono il comportamento console. Il ritorno alla console è una richiesta esplicita al servizio SYSTEM, limitata allo stesso proprietario; accettazione SCM e successo di tscon sono risultati distinti da verificare.

Con `PERPENDICULAR_RDP_PROBE=1` il frontend salva l'inventario nella cartella privata e offre `Return to Windows Desktop`; queste funzioni non attivano RDP né eseguono il login automaticamente. Il normale avvio non presenta il menu della prova. Il dialogo separato richiede la password localmente e invia al helper solo una pipe in memoria. L'interoperabilità viene valutata dopo l'accesso effettivo, senza chiamare questo preparativo un backend già funzionante.
