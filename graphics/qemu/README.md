# Trasferimenti 2D, candidata per il lag Seamless

Esperimento opt-in, **nessun requisito minimo nuovo di produzione**. Il profilo
M1 del 5 novembre osserva `iov_to_buf_full` nel trasferimento 2D del DOD.
Il ramo per rettangoli parziali cerca da capo l'offset di ogni riga nello stesso
iovec. Il cursore conserva soltanto l'indice iniziale della riga; copia,
troncamento, pixel, backing, sincronizzazione e ramo a larghezza intera restano
quelli di QEMU. Questo non dimostra ancora un miglioramento utilizzabile.

`transfer-2d.json` fissa i due sorgenti di partenza e la ricetta. La ricostruzione
usa il QEMU locale compatibile e conserva il fix RAM quiesce; non trasferire un
runtime da un altro Mac e non cambiare pin per superare un rifiuto. L'opzione
di `scripts/rebuild-memory-quiesce.py` è `--transfer-2d-cursor`; quando il cache
precede il fix RAM serve anche `--base-quiesce-receipt` con la ricevuta già
qualificata su quella macchina. La ricetta verifica che il suo output coincida
con il riferimento installato, il cache con la sua base e i sorgenti con i pin.
Tutti i sorgenti/header toccati e il binario del cache vengono ripristinati.
Ninja ricompila anche gli utilizzatori dell'header GPU cambiato.

Confezionare soltanto in una nuova app QA ferma, usando
`scripts/package-memory-runtime.py --native --quiesce-receipt <nuova-receipt>`.
Il packager rifiuta la capacità 2D senza ricevuta/ricetta conforme e conserva
ricevuta e metadata nel bundle. `check-qemu-transfer-2d.py --app <QA.app>` è
anche nel controllo ordinario della build; un runtime che dichiara la candidata
deve contenerla davvero. Rifirmare il frontend con l'identità locale persistente.
Main e payload Windows restano invariati. Primo avvio QA: verificare tutti i
29 membri del runtime effettivo, RAM live, Windows/UMD/protezioni/pixel.

La candidata è **disattivata al boot**. Sull'oggetto virtio-backend dell'uscita
DOD dell'app, QMP espone `perp-2d-cursor` (bool, modificabile) e
`perp-2d-stats` (stringa JSON sola lettura, versione1). I tre gruppi `full`,
`rows`, `cursorRows` accumulano chiamate, byte effettivamente copiati e
microsecondi del corpo della copia. Differenze soltanto sulla stessa istanza,
senza reset; non sono FPS né tempo end-to-end. Confrontare un intervallo con
switch false e uno con true nello stesso video, codec, risoluzione e geometria.
Se i rettangoli parziali non sono pertinenti o il costo è trascurabile, respingere
la candidata invece di promuoverla dal solo risultato del test byte.

`tests/NativeTransfer2DChecks.c` confronta sei casi byte/lunghezza/guardie con
il corpo **non modificato** di `iov_to_buf_full` estratto da `util/iov.c` del
QEMU locale pinnato. Salvare quel corpo come header privato, compilarlo con
`clang -O2 -Wall -Wextra -Werror -DPERP_IOV_REFERENCE='"/percorso/iov-reference.h"'
tests/NativeTransfer2DChecks.c -o /percorso/checks`, poi eseguire. Copre backing
frammentato/segmenti vuoti, padding, ultima riga corta, offset esterno, rewind e
iovec assente. È una verifica di correttezza circoscritta, non un benchmark.
