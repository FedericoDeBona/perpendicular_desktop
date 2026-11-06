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
finché una VM esistente resta viva. Qualifica QA e consegna M4 nella canonica
0.2.84 completate nel perimetro documentato; un altro Mac richiede la propria
compilazione e verifica locale. [Evidenze e limiti](../docs/VERIFICATION.md#consegna-84-nellapp-principale-e-misura-finale).

### Cache M1 dopo le prove GPU ritirate

Il link M1 qualificato contiene758 input oggetto/archivio, contro oltre1000 del
profilo M4. Il controllo ammette il grafo più piccolo; restano obbligatori
ricompilazione HVF originale, uguaglianza di tutte le sezioni codice/dati e
chiusura delle dipendenze prima della candidata. Non basta abbassare una soglia
per qualificare un binario.

Se Ninja conserva gli oggetti di una prova `virtio-gpu.h` mentre i sorgenti sono
stati ripristinati, usare `reconstruct-local-qemu-gpu-link.py` con `--source`,
`--build`, `--ninja`, `--link-command` e un nuovo `--output` privato. La ricetta
ricompila gli utilizzatori registrati di quel solo header fuori dalla cache,
conserva comandi/input/ricevuta e produce `link.command.json`. Passare quel link
al builder CPU ordinario: la successiva uguaglianza con il riferimento
installato resta vincolante. Sul M1 sono stati ricostruiti11 utilizzatori;
nessun oggetto della cache, sorgente o VM è stato modificato.
