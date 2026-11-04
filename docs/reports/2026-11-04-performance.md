# Prestazioni generali — M1, 4 novembre 2026

L'incremento RAM0.2.64 è già distribuito: controller con progresso fisico reale,
restore parziale in background e stop vCPU asincrono. Integrità e arresto normale
qualificati nella copia; allineamento e ritorno a4GiB verificati nella main.
Questo rapporto riguarda il seguito CPU/GPU/disco, senza riaprire Creality
accettato dall'utente. [Consegna RAM](../VERIFICATION.md#4-novembre--consegna0264-e-opengl034-nella-main-m1).

## Componenti e misure

Prima delle nuove misure: canonica.64, runtime host effettivo29/29 conforme,
OpenGLWindows.34, video.1.0, x86 e driverRAM firmatiRunning, kernel e protezioni
conformi ai pin. MainQEMU8741; copia spenta. Il solo frontend.65 cambia poi
la politica di aggiornamento dell'elenco app; nessun nuovo binario host/Windows.

CPU in percentuale di **un core**:100% significa un core occupato. Non sommare
CPU guest e vCPU host. Calibrazione propria100ms sul Mac: rusageCPU è in tick
Mach, timebase125/3; rapporto tempo convertito/process_time_ns1,000305.
La conversione dell'osservatore host era corretta; nessuna correzione delle unità.

La prima misura GetSystemTimes/GetProcessTimes separa kernel/utente ma legge
solo37processi: accesso negato agli altri, inclusoSystem. Non basta per attribuire
il costo a un servizio. La diagnostica finale condivisa
[scripts/measure-guest-cpu.ps1](../../scripts/measure-guest-cpu.ps1) usa i
[contatori Windows](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-counter?view=powershell-5.1)
senza elevazione. Conserva l'intero percorso d'istanza con#n, confronta PID ai
due estremi, scarta processi nati nell'intervallo e campioni invalidi; riporta
errori del provider e costo dell'osservatore. Richiede nomi inglesi dei contatori,
5–30secondi e massimo64CPU; non è un profiler di funzioni.

Esecuzione in Windows: `powershell -NoProfile -File .\measure-guest-cpu.ps1 -Seconds 8`.
Non anteporre istruzioni al blocco `param`; gli invocatori che aggiungono un
prologo devono racchiudere il sorgente in un blocco `& { ... } -Seconds 8`.

Campione finale8,037s:102processi abbinati,0esclusioni/errori provider;
Windows17,29% busy,13,22% kernel,4,28% utente; DPC0,97%, interrupt0,39%.
Contatori distinti, risoluzione e raccolta non impongono somma perfettamente
uguale. System5,05%; workerPerpendicular3908 2,53%; svchost2216 2,33%;
osservatorePowerShell1,36%; servizioPerpendicular3088 0,19%.
Un PID svchost non identifica una singola causa o un driver. Nessuna protezione,
servizio Windows o flush disabilitato.

## Costo evitabile e correzione0.2.65

L'aggiornamento automatico del catalogo passava con `isVisible` anche quando
Desktop Mode aveva il focus: una enumerazioneShellAppsFolder ogni30s sul worker
Windows. Nella main.64,37,7s/13osservazioni: contatore124→125;140,625msCPUworker
nel tratto3,14s che comprende il refresh, contro0–15,625ms negli altri tratti;
171,875ms complessivi. È associazione temporale e conteggio del lavoro,
non una misura isolata della latenza d'input o di FPS.

La.65 esegue il refresh automatico quando il launcher è key e l'app Mac attiva.
Ritorno al launcher/riattivazione recuperano subito il refresh se vecchio almeno30s;
restano controllo connected/loading, refresh iniziale e percorsi espliciti.
Lo stesso predicato è esposto nella diagnostica. Non cambia il polling RAM,
il trasporto frame o la cattura delle app Windows.

Copia.65: Windows allineato, runtime effettivo29hash conformi; Desktop visibile,
37,55s/13osservazioni con eligibilityfalse e contatore1→1. CPUworker46,875ms
nell'intervallo, senza attribuire tutta la differenza alla modifica: copia,
boot e attivitàWindows differenti dal riferimento main. Ritorno reale via menu:
contatore2,49app disponibili e pulsanti abilitati; nessuna duplicazione del refresh.
Distribuzione e verifica main sono registrate nel diario, separatamente.

## Limiti e decisioni per CPU/GPU/disco

Un campione background12,218s a2816MiB stabili mostra QEMU31,17%, frontend1,77%,
renderer sommati1,28%, worker0,13%. Nessun frame nuovo nel percorso grafico
osservato:333submission/ACK invariati, nessuna pendenza. In un precedente
intervallo6,22s anche i contatori di attesa quiesce/reclaim rimangono invariati:
non dimostrata una pausa RAM continua come causa del costo idle.

Nel campione background il Mac registra230.117compressioni,224.694decompressioni,
13.733swapin e31.692swapout (pagine host16KiB). Sono contatori **globali**, non
byte della VM né prova che tutto dipenda dalla RAMWindows. Nodo disco guest:
2.319.360byte/80letture,356.352byte/32scritture; medie1,042ms/8,938ms, nessuna
operazione fallita. Non descrivono la coda o la coda lunga delle latenze.

Due tentativi successivi attraversano cambi di focus/RAM; non costituiscono
un confronto controllato foreground/background. Campione13,21%QEMU con RAM
4096→4060MiB e focus cambiato incluso nei dati, non chiamato idle stabile.
Il tentativo UI di aperturaExplorer non riesce: tasti senza effetto, poi
`noWindowsAvailable`; nessuna latenza di apertura dichiarata. Successiva UI
launcher/Desktop della copia.65 funzionante, senza dedurre affidabilità generale.

`sample` host3s mostra molti thread vCPU in WFI/pselect e mainloop in attesa.
Le frequenze delle stack wall-time non sono quoteCPU, né stack del kernelWindows.
Nessuna ottimizzazione GPU/disco o misura energetica qualificata in questo seguito.
Prossimo passo generale: attribuire paging/compressione del Mac e un'attesa utile
riprodotta, evitando altri tuning finché non c'è un costo e un confronto attendibili.

## Seguito: main0.2.65 e apertura reale

Main.65:29hash del runtime effettivo conformi, stessi componentiWindows/protezioni
verificati dopo avvio normale. Desktop37,665s/13osservazioni: contatore1→1,
eligibilityfalse; ritorno launcher2/49app. Arresto precedente main e successivo
clone entrambi normali, senza forza. La prova principale conferma il conteggio
del lavoro eliminato, non un nuovo confronto percentualeCPU totale.

Apertura FileExplorer dal launcher ora riuscita: prima placeholder, poi documenti
visibili; parti superiori inizialmente bianche conservate come limiteGFX-001.
Intervallo12,172s,0→1finestre, RAM4GiB/pendingfalse/focus true ai due estremi:
QEMU123,56%, frontend6,31%, worker7,57%. Disco44.962.304byte/2286letture,
1.368.064byte/143scritture; medie0,325ms/0,201ms, errori0.
Cache GPU finale1risorsa/11.812.864byte. È costo globale dell'intervallo di apertura,
non prova che l'I/O, la cattura o una singola funzione ne siano la causa;
nessun tempo preciso di apertura o miglioramentoFPS dedotto. Finestra propria
richiusa conCmdW; ritorno al launcher osservato.
