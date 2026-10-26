# Perpendicular Desktop

**Seamless Apps** integra le singole app Windows nel Mac; **Desktop Mode** apre il desktop Windows completo. Nell’interfaccia compatta: **Seamless / Desktop**. Catalogo unico con tutte le app, ultime aperte in alto, ricerca e icone originali ad alta risoluzione conservate sul Mac. Impostazioni della VM per CPU e RAM, con modifiche applicate al prossimo avvio.

Prima di iniziare o riprendere leggere il [registro dei problemi](docs/KNOWN_ISSUES.md), poi il [piano di lavoro](docs/RESTART_PLAN.md) e la [TODO da mantenere obbligatoriamente aggiornata](docs/TODO.md). Il lavoro prosegue su `main` dalla base scelta dall’utente il 25 ottobre 2026.

La base principale è **Perpendicular 0.2.12**, installata in `/Applications/Perpendicular.app`, con collegamento `Perpendicular.app` sul Desktop. App, strumenti di controllo e build selezionano per default la VM in `~/Library/Application Support/Perpendicular Memory IoT`.

La0.2.5 integra il percorso protetto N+1: desktop Windows separato e un’uscita per ciascun monitor Mac, con mapping e scala delle app verificati. Nella main con un Mac fisico sono riusciti testo, drag, resize, dialogo e ripresa dello stesso documento lasciando Windows acceso. Trasferimento fra monitor di scala diversa, cambio monitor e alcuni problemi grafici restano aperti; [stato e limiti](docs/TODO.md#todo-001--schermi-n1), [verifiche](docs/VERIFICATION.md#25-ottobre--integrazione-n1-e-distribuzione-025).

La0.2.4 riduce notifiche ripetute al launcher e consegna i frame direttamente alla UI. Le prove per ridurre l’attesa di presentazione non hanno dato un beneficio qualificato; il presenter precedente è conservato. [Esito pratico e limiti](docs/reports/2026-10-25-graphics-latency-update.md).

La0.2.2 integra l’icona finale «Carbone e cobalto»: documento Icon Composer compilato con i due livelli, fallback ICNS e simbolo nel launcher. Icona e versione osservate nel Finder dopo installazione; nessun avvio della VM per questa modifica.

La sezione Impostazioni sostituisce il pannello dei processi. La0.2.3 mostra un solo controllo principale **RAM massima**, inclusivo della RAM iniziale, che resta sotto Avanzate. Minimo e riserva sono automatici. Il limite riguarda la RAM Windows: grafica e servizi aggiungono consumo sul Mac. I valori salvati si applicano soltanto al prossimo avvio dopo arresto confermato. Base1 GB e aggiunta automatica fino a4 GB osservate nella main protetta; qualifica visiva completa del nuovo pannello ancora limitata dal crash del servizio di automazione UI.

Ripristinato l’accesso automatico Windows senza scadenza, con password originale conservata in LSA: nuovo avvio al desktop senza reinserirla, Secure Boot/CI attivi e modalità test disattivata. Il riavvio ha riprodotto il difetto HVF già noto, distinto dall’accesso automatico. [Verifiche e limiti](docs/VERIFICATION.md#25-ottobre--ram-semplificata-e-accesso-windows).

Questa VM è una nuova Windows 11 IoT Enterprise LTSC ARM64, senza importare i Tools Parallels. Desktop Native3D, driver Microsoft-signed, Secure Boot e Code Integrity attivi, modalità test disattivata. La [RAM dinamica](memory/README.md) è abilitata nella configurazione principale: ciclo effettivo 4→2→4 GiB senza riavvio e dati conservati verificato prima della promozione. Hot-unplug può rimanere parziale per pagine pinned; il balloon compensa senza rimuoverle forzatamente.

La pulizia autorizzata ha eliminato i vecchi dischi VM e launcher. Restano un backup completo offline della IoT, la build originale qualificata come riferimento e i sorgenti/materiali di ricerca conservati per prudenza. La build normale riutilizza il runtime verificato dell'app installata; non lo sostituisce automaticamente con QEMU upstream. Identità, backup e verifiche della promozione sono nel piano.

Restano aperti arresti HVF, saturazione storica delle risorse e gestione dello spazio host. Una breve verifica riuscita non certifica affidabilità generale o compatibilità con tutte le app. Esplora file ed Edge sono disponibili nel launcher e si aprono in finestre Mac tramite immagini GPU. Il difetto noto delle etichette mancanti in alcune catture resta aperto. N+1 è nuovamente richiesto ma non disponibile: il driver/runtime corrente non offre ancora le uscite necessarie. Creality/OpenGL resta rinviato.

- [Report: tempi di apertura di Explorer nel desktop VM, evidenze e possibili colli di bottiglia](docs/reports/2026-10-25-explorer-opening.md)
- [Report: pipeline grafica desktop e finestra individuale, tempi GPU, code e presentazione](docs/reports/2026-10-25-graphics-pipeline.md)
- [TODO: feature, correzioni, stati e criteri di completamento](docs/TODO.md)
- [Requisiti, base attuale e prossimi passi](docs/RESTART_PLAN.md)
- [Implementazione attuale, build e manutenzione](docs/IMPLEMENTATION.md)
- [Problemi aperti e criteri di chiusura](docs/KNOWN_ISSUES.md)
- [Diario cronologico delle verifiche e dei fallimenti](docs/VERIFICATION.md)
- [Indice degli esperimenti ritirati e recupero da Git](docs/RETIRED_EXPERIMENTS.md)

Il diario e Git conservano la storia delle prove. Le descrizioni dei vecchi pacchetti nel diario non sono istruzioni per ripristinare dischi eliminati.
