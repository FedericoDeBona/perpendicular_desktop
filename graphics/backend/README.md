# Operazioni negli errori del backend

`named-errors.patch` aggiunge il nome dell'operazione a cinque messaggi generici
del backend DXMT nativo. Mantiene invariati risultato, frequenza e percorso del
logger, compresi i due `ERR_ONCE`. Non abilita tracing per draw o nuovi retry.

La base è il build privato del backend al commit
`917b721c0f915c6524b416169fdce4427a39524f`. La patch conserva le licenze originali.
`rebuild-native-backend.py` controlla runtime, binario di origine, archivio,
ricette e sorgenti; modifica copie private di tre file e ricompila soltanto le
quattro unità coinvolte (il contesto comune è incluso da due unità).
Produce un runtime nuovo cambiando esclusivamente la libreria backend.

```sh
python3 scripts/rebuild-native-backend.py --reference <build-backend-corrispondente> --runtime <Native3D-verificato> --output <nuova-cartella-privata>
```

La ricevuta dichiara `runtime_verified: false`: compilazione e firma non provano
il funzionamento in Windows. La verifica reale e le operazioni effettivamente
osservate sono registrate in `docs/VERIFICATION.md`. Un messaggio nominato non
dimostra, da solo, che quell'operazione causi il difetto visivo.

## Cattura circoscritta del produttore nativo

`native-bounded-capture.patch` è diagnostica opzionale sulla stessa base
`917b721c0f915c6524b416169fdce4427a39524f`, compatibile con `named-errors.patch`.
Non è applicata al backend ordinario. Il builder sopra conserva i propri input
Wire1: non usarlo per sostituire automaticamente il runtime Wire2 corrente.

La cattura DXGI preesistente dipende da `Present`, che il percorso Neptune
nativo osservato non chiama. Questa patch può catturare invece un solo worker
identificato dal processo e dal contesto effettivi, in una copia isolata.
Richiede `MTL_CAPTURE_ENABLED=1` prima di creare il device e
`DXMT_NATIVE_CAPTURE_DIR` nel solo avvio diagnostico. La directory deve
appartenere all'utente corrente con modo0700; il file vuoto `<PID>.arm` deve
avere modo0600, stesso proprietario e non essere un symlink. Viene consumato
una volta; un trace esistente non viene sovrascritto. Non armare tutti i PID.

La richiesta termina dopo quattro gruppi `CommitChunkInternal` oppure con una
richiesta di stop dopo due secondi, anche se non arrivano altri gruppi. Le
stringhe del codice verificato dicono `max_buffers=4`/`four command buffers`,
ma contano **gruppi**, non tutti i command buffer Metal: il trace reale ne
contiene cinque includendo la coda di inizializzazione. La scadenza dipende
dalla schedulazione del sistema, non è una garanzia real-time.

Inclusa la correzione del valore restituito da `_MTLCaptureManager_startCapture`:
il bridge chiamava Metal senza assegnare `params->ret`. Lo stop viene comunque
programmato dopo la richiesta, per non dipendere dal solo risultato del bridge.
Il primo tentativo senza questa correzione non era delimitato correttamente;
è descritto insieme alla seconda cattura riuscita in `docs/VERIFICATION.md`.

Ricompilare su copie private soltanto `dxmt_command_queue.cpp` e
`winemetal_unix.c`, preservando i quattro oggetti di `named-errors.patch` e
la coppia renderer/server qualificata. Build, trace e risorse catturate restano
nel QA privato: possono contenere pixel delle applicazioni. Dopo la cattura
ripristinare runtime e frontend senza abilitazione diagnostica. Il trace è
evidenza del worker selezionato, non di tutta la composizione Windows.
