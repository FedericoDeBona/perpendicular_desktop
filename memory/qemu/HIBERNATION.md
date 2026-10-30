# Ibernazione Windows: candidata, non disponibile nel prodotto

Requisito TODO-025: uscire da Perpendicular deve salvare la sessione sul disco,
rilasciare le risorse della VM e riprenderla alla riapertura. La semplice pausa
in RAM non soddisfa questo percorso. Conservare un comando di spegnimento completo.

La prima prova M4/Windows ARM64 termina con bugcheck0x1e su
`MRS x8, ERRIDR_EL1` (`0xd5385308`). Il modello ARM comune di QEMU definisce
ERRIDR come costante0 (nessun record RAS), ma questa base HVF non gestisce la
lettura. `hvf-erridr.patch` aggiunge solo la lettura EL1+, lasciando EL0 UNDEF.

La candidata elimina quel sintomo nel successivo campione ma NON rende
funzionante l'ibernazione: nel clone compare bugcheck0x7e/access violation.
Non promuovere la candidata, non abilitare S4/Fast Startup nel prodotto e non
interpretare `hvf_erridr_el1_version=1` come supporto dell'ibernazione.

## Ricostruzione isolata

Servono il sorgente/build QEMU locali e la ricevuta di link che ha prodotto
il QEMU effettivamente installato. Non riutilizzare sorgenti o runtime diversi
per aggirare un rifiuto. La prima base adattata è QEMU10.0.12 UTM/M4, sorgente
HVF SHA256 `f593768ea0fad5ad427b8ad62cc87f48fbc834ee1a3b29764d023ab14b1ac8d8`.
La ricevuta deve riportare l'hash del QEMU canonico corrente.

```
python3 scripts/rebuild-hvf-erridr.py \
  --source /private/qemu/source --build /private/qemu/build \
  --link-receipt /private/qemu/receipt.json \
  --reference-app /Applications/Perpendicular.app \
  --output /private/new-candidate
```

Lo script verifica tutti i membri del manifesto della base, ricostruisce una
baseline con la ricetta conservata e confronta tutte le sezioni di codice/dati
Mach-O con il QEMU canonico prima di compilare la singola unità HVF modificata.
UUID, firma e metadati di link possono cambiare nel relink; non si dichiara
uguaglianza dell'intero file. Originali, VM e app canonica non vengono modificati.
L'output contiene una app separata firmata, patch/pin nel manifesto, ricevuta e
log privati. Le dipendenze impacchettate devono rimanere quelle della base.

## Prossimo criterio

Analizzare il dump kernel Windows del secondo guasto con un lettore di dump
kernel adeguato, identificare modulo/stack e conservare i dati/protezioni.
Un parser di minidump utente non è una misura valida di un dump kernel.
Provare solo nel clone finché una finestra con testo non salvato sopravvive,
con medesimo processo/sessione, grafica e input utilizzabili. Poi integrare UI,
chiusura automatica, stato persistente, compatibilità configurazione/runtime e
verifica main. Bloccare modifiche hardware/configurazione durante stato salvato;
non scartare mai automaticamente una sessione per avviare Windows da zero.

Il primo esito negativo e il secondo candidato sono registrati in
[VERIFICATION.md](../../docs/VERIFICATION.md#30-ottobre--prima-prova-ibernazione-e-bugcheck)
e SYS-007; nessuna qualifica generale e nessuna misura di ripresa riuscita.
