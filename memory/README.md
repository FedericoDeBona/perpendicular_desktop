# RAM dinamica su macOS ARM64

Stato: opt-in, ciclo reale protetto verificato nella nuova Windows IoT ARM64
LTSC pulita e controller automatico verificato anche nel desktop Native3D.
La IoT è ora la VM principale di Perpendicular0.2.1, installata in Applicazioni.
Stato prodotto: SYS-003 in
[KNOWN_ISSUES](../docs/KNOWN_ISSUES.md).

I due script applicano modifiche circoscritte a un sorgente QEMU 10.0.12 UTM
privato, esterno al repository. Rifiutano sorgenti con anchor differenti:

```sh
python3 scripts/patch-qemu-memory.py /percorso/privato/qemu
python3 scripts/patch-qemu-virtio-mem.py /percorso/privato/qemu
```

Il primo mantiene l'ownership delle sottopagine balloon da 4 KiB tra richieste,
per rilasciare una pagina host da 16 KiB soltanto quando tutte le sue sottopagine
sono nel balloon. Una bottom half ferma le vCPU, toglie temporaneamente la
mappatura HVF, applica `MADV_FREE_REUSABLE` e ripristina la mappatura. Il deflate
revoca il suggerimento prima di restituire anche una sola sottopagina. Reset e
cambi di topologia invalidano il tracking. Non cambia il discard generico.

Il secondo abilita virtio-mem su Darwin/HVF: mantiene il protocollo e il bitmap
upstream e sostituisce esclusivamente il backing anonimo privato che il guest
ha ceduto. Durante la sostituzione le vCPU sono ferme e la mappatura HVF assente;
indirizzo host e RAMBlock restano stabili. Shared/file-backed RAM e memslot
dinamici non sono supportati. Il ritorno in uso trova pagine azzerate. Nessuna
pagina ancora posseduta da Windows viene rimossa in base al solo target.

Flag runtime: `PERP_HVF_BALLOON_RECLAIM=1`, `PERP_HVF_VIRTIO_MEM=1`.
Virtio-mem richiede `dynamic-memslots=off`, `memory-backend-ram`, blocchi allineati
(nella prova 2 MiB), memoria massima sufficiente. Il build deve includere GICv3
(questa base lo include abilitando TCG; l'acceleratore selezionato resta HVF).
Le altre patch desktop del runtime qualificato vanno conservate separatamente.
La nuova gestione backing non supporta migrazione/checkpoint dello stato vivo:
un blocker esplicito impedisce di serializzare ownership non migrabile.

Entrambi i device espongono `perp-reclaim-stats` via QOM per distinguere target,
memoria realmente ceduta e fallimenti host. Il contatore di rilascio non basta:
servono footprint Mac, memoria utilizzabile Windows, integrità dei dati e ritorno
al bisogno. Le prove e i tentativi falliti sono nel
[diario](../docs/VERIFICATION.md#25-ottobre--ripresa-ram-e-preparazione-iot-pulita).

Driver balloon e virtio-mem devono essere ARM64 e accettati da Code Integrity
con Secure Boot attivo e TESTSIGNING disattivato. I binari scaricati e i dischi
non fanno parte di questo repository.


Il comando guest `memory_status` usa GlobalMemoryStatusEx. Il controller Mac
interroga guest e device ogni3 secondi: espansione immediata in primo piano,
riserva guest, riduzione graduale128 MiB, prima unplug fisico e poi balloon
quando pagine ancora occupate impediscono la rimozione. La disponibilità guest
bassa sospende il restringimento per60 secondi. Non sospende né riavvia Windows.
Lo snapshot atomico RAM/base/balloon evita conteggi falsi durante l'unplug.

La configurazione opzionale in machine.json è, ad esempio:

```json
{"memoryMiB":2048,"dynamicMemory":{"hotplugMiB":2048,"backgroundMiB":1536,"reserveMiB":512}}
```

Sono campi da aggiungere alla configurazione completa privata; token e dischi
non vanno copiati in Git. Il valore background è un minimo richiesto, non una
promessa di footprint: Windows può trattenere blocchi pinned e il processo ha
anche memoria del renderer/dispositivi. `pending` resta vero se la rimozione
fisica non raggiunge il target. Alla riapertura il controller restituisce il
balloon prima di richiedere tutta la RAM hotadded. Servono app e controller
in esecuzione per la politica automatica; chiudere la sola finestra desktop
mantiene entrambi attivi.

I pin dei due pacchetti realmente provati sono in guest/memory-drivers.json.
Preparare una cartella con Balloon/balloon.{inf,sys,cat} e
VioMem/viomem.{inf,sys,cat}, poi passare `--memory-driver-dir` e la corretta
`--machine-directory` a scripts/bootstrap-guest.py. `--dry-run` verifica i pin
senza creare né collegare media. setup-machine.ps1 include install-memory.ps1:
cataloghi Microsoft Valid richiesti, normale elevazione Windows, nessuna
modifica a Secure Boot o TESTSIGNING. Non installa l'intero set di Tools UTM.

scripts/package-memory-runtime.py confeziona un QEMU già compilato e tutte
le sue dipendenze Mach-O in un nuovo pacchetto privato; --native aggiorna solo
l'eseguibile QEMU e il suo hash nel manifest grafico, conservando renderer,
server e backend. Il campo hvf_dynamic_memory_version=1 permette al frontend
di rifiutare un vecchio runtime nativo incompatibile. Il flag non sostituisce
la verifica reale. Il pacchetto può selezionare la VM tramite la chiave privata
Info.plist PerpendicularMachineDirectory o l'override di ambiente omonimo
PERPENDICULAR_MACHINE_DIRECTORY; il default ordinario è ora la cartella IoT.
Le build normali riutilizzano il runtime principale tramite copy-main-runtime.py,
anziché ricostruirlo con il preparatore upstream.

Le patch native aggiuntive conservano i tre handler HVF e il monitor della
base64a5e90 (native-desktop.patch), espongono EGL headless tramite ANGLE Darwin
(native-egl-headless.patch), e consentono una finestra PCI alta1 GiB in un
runtime HVF con entrambi gli opt-in RAM (native-memory-map.patch). Quest'ultima
rinuncia al minimo legacy256 GiB solo quando la finestra è esplicitamente più
piccola del default512 GiB. Il frontend la richiede per RAM dinamica+Native3D;
serve per il BAR GPU512 MiB, che non entra nella finestra bassa allineata, quando
l'apertura alta legacy eccede il PA range. La topologia normale resta invariata.
Il fetch istruzione consulta RamDiscardManager per i soli4 byte popolati;
non legge RAM hotremoved. Applicare queste patch dopo gli overlay scanout,
protocollo e input della base nativa corrispondente, non su QEMU upstream puro.
Nessuna patch consumer-demand o modifica WGC fa parte del percorso RAM.
