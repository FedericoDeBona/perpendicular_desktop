# LOK Digital — sfide tra amici

Il collegamento Windows **LOK - Sfide giornaliere** apre la copia con profilo `LOKDailyTest/LOK`. **Rigenera puzzle** sostituisce la terna attiva. Riaprire una sfida fa partire il cronometro da zero e mostra i tentativi completati della stessa griglia.

I primi due puzzle mantengono il profilo difficile originale. Per il terzo, il generatore di LOK sceglie la disposizione delle tessere, i percorsi e le rotazioni, con un piano di 7–9 mosse. Il piano sceglie da 2 a 4 bersagli con vetro, da 1 a 3 strati per bersaglio e un'eventuale mossa LOK. Una mossa aggiuntiva sullo stesso bersaglio diventa uno strato di vetro. Le griglie ammesse usano TA, TLAK e, quando presente, LOK. La verifica richiede che un eventuale LOK tocchi un'altra parte della griglia.

Il controllo riproduce le mosse sulla griglia finale. Per certificare anche la lunghezza minima, conta i colpi sui bersagli a lettera unica. TA e LOK possono coprire al massimo un colpo per mossa e TLAK due, consumando una L e una K. Se c'è una O, consumarla richiede un ulteriore colpo oppure un LOK che consuma una coppia L/K. Il controllo richiede che questo limite inferiore coincida con la lunghezza della soluzione. Il ventaglio di lettere è vincolato affinché non siano possibili poteri estranei a questa dimostrazione. Il generatore scarta i candidati che non superano entrambi i controlli. Se termina il budget casuale, ricostruisce e ricontrolla un candidato già certificato della stessa lunghezza mediante il suo seed.

## Compilazione e installazione

Eseguire `build.ps1` in Windows PowerShell con la build Windows di LOK Digital 1.0.1 (16728078) e il file `lib/net40/Mono.Cecil.dll` dal [pacchetto Mono.Cecil 0.11.6](https://www.nuget.org/packages/Mono.Cecil/0.11.6). Lo script controlla gli hash del compilato originale, del runtime Unity e di Cecil. Produce i due file locali in una nuova cartella, sullo stesso volume della copia se si installa.

```powershell
.\build.ps1 -OriginalGame $original -Cecil $cecilDll -OutputDirectory $output
```

Passare anche `-ChallengeGame $copy` per installare nella copia chiusa. Per aggiornare una copia su cui è già presente la modalità, passare `-PreviousBuild $previous` con la cartella dei due file effettivamente installati. Lo script controlla l'identità del profilo separato, confronta gli output e conserva i file sostituiti. La copia compatibile usa `LOKDailyTest` al posto di `IcedropGames` nei due file Unity `LOK_Data/app.info` e `LOK_Data/globalgamemanagers`, agli offset 0 e 1304.

Il record locale è `FriendChallenges.txt`. Al primo avvio della nuova versione, i tempi delle prime due griglie sono riletti con lo stesso seed, mentre il record precedente viene conservato in `FriendChallenges.txt.before-glass-update` perché il terzo puzzle è diverso. I file del gioco e i risultati personali restano sulla macchina.
