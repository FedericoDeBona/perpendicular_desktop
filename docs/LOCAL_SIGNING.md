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

Anche i programmi Samba e i due helper VPN vengono firmati con il certificato
locale persistente e identificativi distinti stabili. Una firma persistente del
solo frontend non basta a qualificare l’identità dei suoi componenti.

L'installer rifiuta Windows e frontend canonico aperti. Arresta soltanto i server
Samba appartenenti alla VM selezionata, con Windows già spento, prima di muovere
la loro app responsabile. Verifica firma/requisito prima e dopo la copia.
I rollback sono archivi `.tar.gz` privati, con contenuti verificati prima della
rimozione della copia eseguibile; le vecchie `.bundle-backup` riconosciute vengono
archiviate e deregistrate. Cambiare soltanto l’estensione non rende un bundle
non eseguibile e non impedisce l’attribuzione dei consensi a una copia storica.
Per ripristinare, con app/Windows spenti, estrarre l’archivio in una directory
privata e installare il suo `Perpendicular.app` con l’installer; registrare solo
la canonica. Un rollback alla vecchia identità può richiedere nuovo consenso.

La verifica .79 ha eliminato gli avvisi del backup secondo l’utente, ma ha ancora
richiesto quelli di Perpendicular nel primo passaggio. Due successive build.80/.81 hanno mantenuto i requisiti e collegato le cartelle.
Nel successivo avvio.81 l’utente conferma «Nessun avviso né password»: continuità
verificata in questo ciclo main fra build diverse. L’altro Mac e l’uso prolungato
restano da qualificare. Non sostituire il riscontro reale con l’assenza di clic CUA.

Riferimenti Apple: [requisiti di firma](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[certificati locali e identità](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
