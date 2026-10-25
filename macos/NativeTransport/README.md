# Trasporto delle superfici native

`ndt.c` e `ndt.h` sono il componente MIT importato dal trasporto nativo del progetto di riferimento, mantenuto senza modifiche. Il runtime attuale usa il protocollo guest Wire2 e il contratto immagini host-v3/descriptor-v2: il cambio del protocollo guest non cambia da solo il contratto del consumer Mac. Non sono importati il vecchio engine, agent, sharing o interfaccia.

Il contratto verifica UID/PID del produttore, sessione, epoch, identità del frame, dimensioni, descrittori e segnale di completamento. Il consumer conserva la memoria finché terminano gli effettivi lettori Metal; soltanto l’ACK esatto autorizza il riuso. Una disconnessione non autorizza il riuso.

SHA-256 delle sorgenti di riferimento:

- `ndt.c`: `caf9a9428687b4a727113259492d0cc06027afe034cfebfc2cfae668603583b5`
- `ndt.h`: `04e32cb87fa643fb1c14f55fe416d3dde3a047ca73cabb2da19250a4b1725895`

La verifica dell’integrazione avviene con una breve prova del desktop reale e del suo recupero. La copia GPU e i limiti del percorso sono descritti nell’[implementazione corrente](../../docs/IMPLEMENTATION.md).
