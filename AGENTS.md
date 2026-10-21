# Regole di lavoro

Leggi [docs/RESTART_PLAN.md](docs/RESTART_PLAN.md). Le istruzioni dell'utente hanno precedenza.

- Parti dai requisiti del prodotto. Linguaggi, librerie, protocolli e struttura interna richiedono una scelta motivata sul sistema effettivo.
- Distingui requisiti dell'utente, ipotesi tecniche e capacità realmente verificate.
- Consulta implementazioni o esperimenti precedenti soltanto per rispondere a una domanda precisa; non ereditarne automaticamente architettura, dipendenze o conclusioni.
- Verifica prima il percorso minimo completo. Registra anche errori e tentativi falliti; non presentare una singola riuscita come prova di affidabilità generale.
- Fai pochi test mirati: privilegia una breve prova end-to-end nell'app reale e aggiungi controlli automatici soltanto per dubbi concreti o logica critica. Non costruire centinaia di test, grandi harness, benchmark estesi o test che replicano l'implementazione. Dopo una verifica riuscita prosegui; ripetila solo per modifiche pertinenti o nuovi problemi. Non incastrarti a perfezionare un sottocomponente: completa piccoli passaggi utilizzabili.
- Mantieni separabili i componenti necessari, senza costruire astrazioni per funzioni non ancora richieste.
- Preserva i dati e le modifiche dell'utente. Tieni credenziali, dischi delle VM e artefatti generati fuori dal repository.
- Durante il lavoro, crea commit e fai push su GitHub ai passaggi completati e verificati, senza aspettare una nuova richiesta dell'utente. Raggruppa modifiche coerenti; non pubblicare credenziali, stato privato della VM o artefatti generati. Non usare push forzati.
