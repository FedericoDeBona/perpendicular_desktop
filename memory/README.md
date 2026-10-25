# RAM dinamica su macOS ARM64

Stato: implementazione sperimentale, opt-in. Compilazione e avvio dei dispositivi
verificati; il ciclo nel Windows IoT pulito è ancora in verifica. Non abilitare
una riduzione automatica dal solo ritorno QMP. Stato prodotto: SYS-003 in
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
