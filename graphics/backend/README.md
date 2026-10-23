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
