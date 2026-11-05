# Esperimenti di cattura

`wgc-release-before-ack.patch` è una candidata **non promossa**, basata su
`973b73c`: `git apply --check` e `git apply` dalla radice, poi la normale
build ARM64 del guest. Conserva l’export GPU immutabile fino all’ACK ma
rilascia le interfacce e il frame WGC dopo la query e prima dell’attesa.

Il 5 novembre è stata compilata e installata nella main (SHA DF8DB775…),
ma non ha dato un miglioramento utile: circa 5,35 catture/s contro 5,9
nel campione precedente, con istanza e geometria diverse (nessun A/B
causale). `sourceReleasedBeforeAck` significa prima dell’attesa locale,
non misura l’istante dell’ACK remoto. I sorgenti di produzione restano
quelli della 0.2.70; ripristinare anche il servizio installato prima di
considerare allineata l’app principale. Non ripetere la prova senza una
nuova domanda precisa. Evidenze e limiti in
[VERIFICATION](../../docs/VERIFICATION.md#5-novembre--ripresa-flicker-seamless-edge-e-task-manager).
