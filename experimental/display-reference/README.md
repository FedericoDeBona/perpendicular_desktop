# Tentativo display ritirato

Il vecchio 2D non è una base approvata. Il suo runtime, il preparatore DOD e il selettore `virtio2D` non fanno parte di app, guest o CD ordinari.

- Nei tentativi con QEMU 10 e DOD sono stati osservati selezione persistente del precedente driver 3D, codice 43, riavvio interno e output display non attivo. Non è stato ottenuto un percorso funzionante verificato.
- Il candidato QEMU 11.1.2 recuperato è stato controllato soltanto per hash, firma, dipendenze, versione e disponibilità del dispositivo. Non è mai stato avviato con la VM corrente.
- Gli artefatti e i preparatori scartati rimangono privati in `.build/RetiredDisplayReference`, fuori dal repository. La build ordinaria non li importa.

Le riuscite storiche non dimostrano avvio affidabile, correttezza visiva o risoluzione dinamica. Un'eventuale ripresa richiede una nuova scelta e una breve prova nell'app reale. Vedere [IMPLEMENTATION.md](../../docs/IMPLEMENTATION.md) per la direzione corrente.
