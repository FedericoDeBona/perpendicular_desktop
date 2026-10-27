# LinkManager 11.9 — studio statico Windows ARM64

Data: 27 ottobre 2026. REA 6.5.0 con Ghidra 12.1.4.

## Esito

Il pacchetto originale non offre driver Windows ARM64. L’emulazione Windows x86/x64 riguarda il codice utente e non rende caricabili questi driver kernel Intel. Il funzionamento completo del pacchetto in una VM ARM64 non è quindi ottenibile con la sola esecuzione o modifica del bootstrap dell’installer.

La sola parte Ethernet presenta un percorso di adattamento tecnicamente plausibile. È una conclusione di fattibilità statica, non un risultato di esecuzione: nessuna installazione, compilazione, modifica dei binari o prova nella VM è stata svolta.

## Provenienza e perimetro

Originale: `/Users/federico/Downloads/v6051_11.9.626364010_LinkManager_Setup.exe`.
SHA-256: `e8cf6131dd37d91bcda35a2de7f61f910c62be0bddf5d8a91ecb0dd82a01f03c`.

La decompressione NSIS è stata effettuata con 7-Zip e Python/lzma, non con REA. Gli offset del flusso decompresso e gli hash dei file derivati sono in `provenance.json`. REA ha successivamente aperto e decompilato in sessioni Ghidra i file derivati LinkManagerSvc.exe, LinkManagerTray.exe e una copia x64 di lmtap.sys. tapmgr.exe è estratto e identificato, ma non decompilato separatamente. La prima ricognizione aveva inoltre inventariato i payload x86/x64 e gli INF, senza rilevare ARM64. I documenti incorporati sono stati trattati esclusivamente come dati.

## Nuove osservazioni nel codice

1. Nel servizio, la funzione `0x140003020` enumera i driver disponibili tramite SetupDi e confronta il loro HardwareID con `lmtap`. Non è una deduzione dal solo nome del file: il confronto compare nello pseudocodice.
2. Il servizio `0x140005a50` e la routine equivalente nel Tray `0x140088360` aprono `\\.\Global\<GUID>.tap`, inviano `0x220008` (GET_VERSION, buffer 12 byte) e chiamano `0x22002c` soltanto se la major restituita è minore di 9. Non si deve assumere la compatibilità di quel ramo legacy: nell’header OpenVPN corrente lo stesso numero indica PRIORITY_BEHAVIOR. Il driver Secomea esaminato restituisce major 9, minor 23, quindi evita tale ramo.
3. La routine di rete Tray `0x140095e70` invia `0x220018` con un intero da 4 byte per attivare e disattivare il collegamento. Le routine `0x1400964e0` e `0x1400965e0` scambiano i dati mediante WriteFile/ReadFile e I/O OVERLAPPED; `0x1400967f0` apre il percorso TAP standard.
4. Nel driver `lmtap.sys`, la funzione `0x14000a360` contiene la gestione di `0x220004` (GET_MAC), `0x220008` (GET_VERSION), `0x22000c` (GET_MTU), `0x220018` (SET_MEDIA_STATUS). Gli altri codici seguono il ramo INVALID_DEVICE_REQUEST in questa funzione. Questo rafforza la compatibilità del confine osservato con TAP standard, senza dimostrare l’equivalenza dell’intero driver.
5. Il Tray ha anche una routine di rimozione `0x1400869c0` che accetta gli HardwareID `lmtap` o `vboxtap`. Il riconoscimento è specifico, non limitato al nome visualizzato della scheda. Un normale adattatore OpenVPN non è dimostrato come sostituto diretto.
6. Dei quattro chiamanti diretti di DeviceIoControl recuperati nel Tray, due riguardano il TAP; gli altri due esaminati riguardano la comunicazione seriale. Il perimetro osservato non esclude meccanismi indiretti non risolti o altri percorsi dell’applicazione.

## Percorso possibile, non implementato

- Conservare il codice utente x64 sotto emulazione Windows e fornire un driver TAP ARM64 compatibile con identità e contratti attesi da LinkManager; in alternativa adattare la selezione del dispositivo nel programma per un TAP ARM64 esistente.
- Verificare l’installazione degli adattatori e le chiamate SetupDi in un processo emulato. Non è ancora dimostrato che tutti gli helper dell’installer funzionino su ARM64.
- Usare un pacchetto driver validamente firmato per il sistema target. Rinominare un file o cambiare un INF non converte l’architettura e non conserva automaticamente la validità del pacchetto firmato.
- Ottenere, se possibile, i sorgenti corrispondenti della variante Secomea. La pagina delle licenze incorporata dichiara la disponibilità su richiesta al rivenditore; non è stata inviata alcuna richiesta.
- USB e seriale sono separati: il fatto che esistano progetti ARM64 con funzioni analoghe non prova la compatibilità con i contratti Secomea. I relativi driver non sono stati decompilati in questa seconda passata.

Il progetto originale TAP-Windows6 supporta ARM64, richiedendo NDIS 6.30 su tale piattaforma. Questo rende credibile un porting del componente di rete; non dimostra che il binario generico sia intercambiabile.

## Fonti primarie consultate

- https://github.com/OpenVPN/tap-windows6 — supporto ARM64 e requisiti NDIS.
- https://raw.githubusercontent.com/OpenVPN/tap-windows6/master/src/tap-windows.h — nomi e codici IOCTL, percorso del dispositivo. Riferimento upstream corrente, non sorgente autenticato della variante Secomea.
- https://raw.githubusercontent.com/OpenVPN/tap-windows6/master/src/device.c — implementazione upstream dei controlli.
- https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation — emulazione del solo codice utente e necessità di driver ARM64.

## Evidenze REA selezionate

I file JSON contengono i record completi, inclusi hash del target, profilo Ghidra e limiti. `evidence-index.json` indicizza anche le ricerche senza esito (per esempio la prima ricerca del nome non qualificato DeviceIoControl).

- Creazione adattatore: confronto HardwareID con lmtap: `ev_fec94c9135ca5c7cbf67b6c550d2245c11409f4f5c16936f6a2f7822f0cacc56` — [011-tools-call.json](011-tools-call.json).
- Servizio: apertura TAP, versione e ramo legacy: `ev_c6885e5f90584f04ce7819489258e5ec07856f4ab5782872f926f645f13e2856` — [012-tools-call.json](012-tools-call.json).
- Tray: apertura TAP, versione e ramo legacy: `ev_5be40ab74e7bd5ae004617a3d21c2677ef733bb3ab03585b73d8f7f62ebe10d3` — [019-tools-call.json](019-tools-call.json).
- Tray: attivazione/disattivazione media con 0x220018: `ev_e5927989f223ee42152eacc6c9a488bdc51f60962caf66092708f0fe268407a6` — [022-tools-call.json](022-tools-call.json).
- Tray: invio pacchetti con WriteFile: `ev_2891ef5791c3ff6675f46f1bcb08473722feba50411f6c88fc9a1249c68aea98` — [024-tools-call.json](024-tools-call.json).
- Tray: ricezione pacchetti con ReadFile e OVERLAPPED: `ev_6572e59f63feb78090a9175e2ff1aba93f191c7d7f75234cbe987edcee3d18ed` — [025-tools-call.json](025-tools-call.json).
- Tray: costruzione del percorso standard TAP: `ev_3352ace05ac070709a376c41a70d5c9a5b09f0b4471f5483d2a20d311ee5a9ba` — [029-tools-call.json](029-tools-call.json).
- Tray: riconoscimento HardwareID lmtap o vboxtap per rimozione: `ev_297afdd0ac24cad7f3fdf2717f6065a453dece4b243f1c9309bab381086f2322` — [030-tools-call.json](030-tools-call.json).
- Driver lmtap x64: dispatch IOCTL: `ev_9cfb91e9b07bbaf1d997d4c3906f154f41de91a55a6d4dcabd622b751877c4da` — [038-tools-call.json](038-tools-call.json).

## Limiti

Pseudocodice recuperato, non sorgente originale. Ghidra segnala, tra le altre cose, blocchi irraggiungibili rimossi, sostituzioni dei controlli stack/cookie e sovrapposizioni di globali; nel driver alcuni tipi e dettagli dello stack sono imperfetti. Le conclusioni si limitano ai confronti, costanti e chiamate osservati nei percorsi descritti. Nessun test operativo, connessione GateManager, validazione delle firme Windows o verifica completa di USB/seriale. Non è stata avviata nessuna copia dei programmi Windows. Le sessioni native REA sono state chiuse al termine.
