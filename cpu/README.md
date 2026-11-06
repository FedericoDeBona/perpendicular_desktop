# Attesa CPU quando la VM non ha finestre

`requirements.json` è l'autorità condivisa. La patch conserva la finestra busy
originale di 2 ms durante l'uso; un lease host la riduce a 250 µs solo senza
Desktop, finestre Seamless o aperture in corso. Il lease scade dopo 10 secondi.
Il frontend conferma il ritorno a 2 ms prima dei lanci espliciti e di ogni
apertura Desktop. Non modifica CPU assegnate, piano energetico Windows, RAM o
topologia degli schermi.

La compilazione usa **i sorgenti e il link del Mac corrente**, preservando le
altre correzioni. Non trasferire il runtime di un altro Mac o cambiare i pin.
Occorrono Xcode, sorgenti/build QEMU conservati e il comando JSON di link che
riproduce il QEMU installato (inclusi gli overlay RAM/grafici più recenti).

```sh
python3 scripts/rebuild-hvf-idle.py \
  --source /percorso/locale/source --build /percorso/locale/build \
  --link-command /percorso/locale/candidate-link.command.json \
  --reference-app /Applications/Perpendicular.app \
  --machine-directory /percorso/della/VM-di-prova \
  --output /nuovo/percorso/privato/cpu-build

python3 scripts/package-cpu-idle-runtime.py \
  --source-app /nuovo/percorso/privato/cpu-build/Perpendicular.app \
  --receipt /nuovo/percorso/privato/cpu-build/receipt.json \
  --output /nuovo/percorso/privato/cpu-payload/Perpendicular.app
```

La ricetta ricompila prima l'unità HVF originale: codice/dati e dipendenze del
link fresco devono coincidere col riferimento. Poi applica la patch a una
copia e ricompila soltanto quell'unità. Input/cache/sorgenti e VM non vengono
modificati. La ricevuta privata conserva pin e comandi; non va pubblicata in
Git. Il pacchetto conserva la firma persistente del frontend e tutte le altre
librerie del riferimento.

Usare il pacchetto locale come `PERPENDICULAR_RUNTIME_APP` nella build ordinaria,
selezionando esplicitamente `PERPENDICULAR_MACHINE_DIRECTORY` della destinazione.
`check-cpu-idle-runtime.py` rifiuta vecchi payload, patch diverse, capacità
assenti o hash QEMU non coincidenti. Il packaging prova la provenienza;
misura del beneficio, scadenza del lease e riapertura normale devono essere
qualificate nella copia e poi nell'app principale. Confrontare sempre anche
gli artefatti del runtime effettivo: il frontend aggiornato non li sostituisce
finché una VM esistente resta viva. [Evidenze e limiti](../docs/VERIFICATION.md#ritorno-al-riferimento-e-scelta-della-sola-modalità-idle).
