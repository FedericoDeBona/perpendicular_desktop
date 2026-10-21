# Parallels: evidenze statiche utili — 21 ottobre 2026

Analisi mirata con REA di Parallels Desktop **27.0.3 (58680)** installato sul Mac.
Non sono stati avviati Parallels o VM, né modificate configurazioni o protezioni.
Le osservazioni sotto non ricostruiscono il protocollo Coherence o il suo comportamento runtime.

## Identità e conservazione

- Framework originale: `/Applications/Parallels Desktop.app/Contents/Frameworks/ParallelsVirtualizationSDK.framework/Versions/11/ParallelsVirtualizationSDK`.
- SHA256 originale universal: `3fc83b8938ede4fc5ed385c2dcdea949da7f5302f4491ed868df4be39c84ae2a`.
- Per Ghidra è stata estratta con `lipo -thin arm64` una copia temporanea, senza modificare l'originale.
- SHA256 slice ARM64: `a7396393fb90cc3095cce5090431063456bd0b0b5c33711c20cf84878cb0862d`.
- Identità Mach-O: `ev_a757666611aaf011974a7ef51ef8cee25f4be4a2c79353f2b5dc958d10948b57`.
- Bundle completo, fuori Git: `~/Library/Application Support/Perpendicular Research/REA/parallels-27.0.3-20261021.json` (8 record).

Nel repository non sono conservati binari derivati, disassemblati, pseudocodice proprietario o dump.

## Osservazioni

1. Il SDK espone operazioni distinte per configurare il display (`SetConfiguration`), leggerne dimensioni e disponibilità della risoluzione dinamica (`GetScreenSize`, `GetDynResToolStatus`), ottenere/catturare immagini, gestire superfici e inviare input mouse/tastiera. Espone inoltre preferenze separate `HighResolutionEnabled` e `HighResolutionInGuestEnabled`.
   Evidence: `ev_7401f814f992f51e434f9ce05a668a6426b1e446f77d33088a95755a68027449`.
   Il provider non dichiara esaustivo l'inventario degli export; i nomi da soli non provano l'uso runtime.

2. La wrapper di `SetConfiguration` verifica tipo dell'handle e puntatore, ottiene il collegamento e inoltra una sequenza di record. Restituisce l'esito dell'inoltro; nella wrapper esaminata non rilegge la modalità effettivamente applicata.
   Evidence: `ev_d40b5df55ee781d96c45a6c6d6690aa25bc725ef6d23421c12a3005c284073fa`.
   I campi dei record e il protocollo completo non sono stati ricostruiti.

3. `GetScreenSize` segue una query distinta sullo stesso tipo di handle; `SyncSetScreenSurface` segue un'altra chiamata interna. È osservabile una separazione fra richiesta di configurazione, lettura delle dimensioni e superficie.
   Evidence: `ev_dc734089a158a683bd1c2ce04e64c1f521ab5aa4cff1c2f38011891d9ffd7624`, `ev_8ca0a8eb5ac7a7a4d5250a7057a747366b7b7becb9992ddb4b5ffa2a6622a932`.

4. Le stringhe includono diagnostiche Coherence per configurazioni display host/guest non valide, perdita della configurazione guest e display insufficienti. Suggeriscono prerequisiti monitor espliciti; non dimostrano la sequenza di controllo effettiva.
   Evidence: `ev_6e3461b43a3187a49f1f47738a8511d92b2899e5b5cd38da72a14b6bc9fca998`.

## Contratto pratico per Perpendicular

Queste sono scelte del nostro progetto, coerenti con i requisiti; non sono il protocollo di Parallels.

- Configurare il monitor e rileggere risoluzione e DPI effettivi prima di abilitare la geometria condivisa. EDID o comando accettato non bastano: `SharedDisplay` deve qualificare lo stato osservato.
- Distinguere richiesta ricevuta, operazione accettata e stato finale osservato. La configurazione del display appartiene ai monitor, non al resize di una singola app.
- Collegare a finestre, immagini, input e popup la stessa trasformazione fra punti Mac e pixel Windows; superare la scala iniziale scelta solo per contenere il primo frame.
- Per drag/resize conservare identità della finestra e della connessione, revisione del gesto e geometria finale confermata da Windows. Risposte vecchie non devono annullare il gesto corrente.
- Confermare separatamente attivazione e destinazione dell'input; preservare il rilascio di tasti/pulsanti anche quando la geometria cambia o la finestra viene ritirata.
- Mantenere separabili monitor, controllo finestre, cattura/trasporto e accelerazione. Metal sul Mac non dimostra accelerazione Windows né assenza di copie CPU.

## Limiti e tentativo fallito

Il primo target `prl_vm_app` ARM64 (SHA256 `79afaead95e143397c0e753ee9a2196fca6226eea74b635f855cb68539d786f3`) non ha completato l'autoanalisi Ghidra entro 330 secondi; il log riportava anche errori interni del decompilatore. Non sono state ricavate conclusioni dal risultato incompleto. Il successivo componente SDK più piccolo ha completato l'analisi statica con Ghidra 12.1.4; la sessione è stata chiusa.

Restano ignoti ordine runtime della configurazione/DPI, politiche di focus, formato completo dei messaggi Coherence, cattura/trasporto delle singole finestre e rapporto effettivo fra tali immagini e accelerazione. Nessuna prova di compatibilità del backend Perpendicular deriva da questi risultati: serve una breve verifica nell'app reale.
