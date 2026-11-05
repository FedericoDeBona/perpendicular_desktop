# Firma locale e permessi delle cartelle

Le build locali devono conservare l'identità di firma tra versioni. La vecchia
firma `codesign --sign -` generava una designated requirement basata sul cdhash:
modificare il programma cambiava l'identità cui macOS associa il consenso.
Non ripristinare quella firma e non usare un requisito basato sul solo bundle ID.

Su ciascun Mac, una volta:

```sh
python3 scripts/sign-macos.py --setup
```

Poi usare la build e l'installazione ordinarie:

```sh
zsh scripts/build-guest.sh
zsh scripts/build-macos.sh
# Arrestare normalmente Windows e uscire da Perpendicular prima di installare.
python3 scripts/install-macos.py
```

La chiave/certificato e il portachiavi dedicato risiedono in
`~/Library/Application Support/Perpendicular Signing` (privato, fuori Git).
Il certificato locale dura dieci anni. Non copiarlo dall'altro Mac, cancellarlo,
rigenerarlo o pubblicarlo. Perdita/scadenza richiedono una nuova identità e un
nuovo consenso: la build deve fallire, senza ripiegare su firma ad hoc. Un setup
parziale fallisce e richiede recupero esplicito, senza rotazione automatica.
Il requisito vincola bundle ID **e certificato effettivo**; i byte di ogni build
restano verificati dalla firma. Nessuna modifica a TCC, trust store o protezioni.
È una firma per sviluppo/installazione locale, non per distribuzione pubblica o
notarizzazione; per quelle serve un'identità di distribuzione appropriata.

Il primo passaggio dalla firma precedente può richiedere nuovamente i consensi
Scrivania/Documenti/Download. La verifica pertinente è conservare l'accesso dopo
una build diversa firmata con lo stesso certificato, non soltanto rilanciare lo
stesso eseguibile. Non cancellare TCC o concedere accesso completo al disco.

L'installer rifiuta la sostituzione mentre il frontend canonico è aperto,
verifica firma e requisito prima/dopo la copia, conserva rollback fuori Git con
estensione `.bundle-backup` e registra soltanto la canonica. Non rinominare app
in esecuzione in `Before-*.app`: copie con lo stesso bundle ID possono essere
risolte da Launch Services al posto della canonica, anche per il nome nei
consensi. Per ripristinare un rollback, app chiusa, ricopiare il suo contenuto
come `/Applications/Perpendicular.app` e registrare la canonica; la firma vecchia
può richiedere consenso. Non avviare direttamente il backup.

Riferimenti Apple: [requisiti di firma](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[certificati locali e identità](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
