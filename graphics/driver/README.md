# Esperimento di avvio dei comandi sotto lo scheduler Windows

**Candidata non qualificata e non integrata nel prodotto.** Nel seguito autorizzato del24 ottobre sono stati superati caricamento e creazione del dispositivo Direct3D nel clone. La DLL ricompilata abilita ora lo scheduling soltanto nel processo che imposta `PERP_DRIVER_SCHEDULE_TRIAL=1`; occorre anche `NPT_PERF=multi_ring`, perché il ring privato dipende da quella capacità. Con entrambe le opzioni la prova raggiunge Wait/Clear/Copy/Signal, ma query e tutti4096pixel completano ancora con fence0. Quindi la candidata non corregge l’ordinamento e non dimostra un miglioramento grafico.

## Domanda e modifica candidata

Il controllo esistente `scripts/check-graphics-fence-wait.py` aveva dimostrato che sul pacchetto ufficiale v0.4 il lavoro D3D11 successivo a un Wait può completarsi prima del Signal. Quella prova non identifica la causa di ogni superficie WGC incompleta.

Le patch conservano una candidata per subordinare l’avvio sul Mac allo scheduler Windows:

- UMD: ring privato dell’immediate context, più un ring separato usato soltanto per i contatori di autorizzazione. Prima di inoltrare un comando, accoda un pacchetto sul contesto kernel del runtime e inserisce nel ring del comando un’attesa del contatore corrispondente. Il ring distinto evita che i normali round trip per creare risorse soddisfino accidentalmente l’attesa dello scheduler.
- KMD: comando sperimentale `0xB`, che alla sua esecuzione invia `RING_SUBMIT_VQ_SEQNO` al contesto Neptune indicato. L’indirizzo è ammesso soltanto se appartiene a un contesto Neptune vivo dello stesso processo del dispositivo mittente. Il protocollo host Wire2 e i binari Mac restano invariati.

È un esperimento sull’**avvio**. Non aggiunge un nuovo collegamento fra completamento GPU D3D11 e segnali monitorati di Windows, non implementa il percorso D3D12 e non qualifica prestazioni, concorrenza, distruzione dei contesti o recupero da errori. Il costo di un invio kernel per comando non è stato misurato. Non promuovere queste patch senza una prova reale e una verifica dei limiti di completamento e durata delle risorse.

## Input e verifiche effettuate

- KMD: `osy/kvm-guest-drivers-windows`, tag v0.4 / commit `a3422e7bd946b5295ec646bc1e60fde1bc48ce53`.
- UMD: `osy/virtio-win-mesa`, commit `bf536bba65454900d782fa7417bc95c1608d7483`, protocollo compatibile Wire2/f510.
- Prima build privata sul Mac: Apple Clang 21, LLD 23.1.1, SDK/WDK ARM64 26100; versioni58001 e58002 non caricate, problema39. Le differenze dei flag PE non hanno isolato la causa.
- Successiva build nativa: MSVC/link Microsoft ARM64, impostazioni kernel dai props WDK. Versione58003 senza risorsa VERSIONINFO: problema31/`0xC0000182`. Una traccia DxgKrnl delimitata segnala esplicitamente la risorsa di versione mancante e il fallimento AddDevice. Aggiunta solo quella risorsa e rifatto il link sugli stessi oggetti: versione58004 caricata, problema0. È una correzione della ricetta sperimentale, non della logica delle fence.
- SYS58004 firmato, corrispondente al percorso del servizio Running: `08341958ac0a2eeebe1663c29c0e97cfab054d4e568548b066fdbefbc35022c0`. DLL candidata nel pacchetto, rimasta invariata durante queste correzioni di build: `b2f98d2f1a081af0b844b5506be658ddbec0732438a5bb552f342318303ea122`.
- DLL **ARM64 nativa**, non una ricostruzione completa ARM64X. Le altre DLL del pacchetto ufficiale sono rimaste invariate. Caricamento manuale della DLL candidata e ricerca di OpenAdapter10_2 riusciti nel processo ARM64 nativo; nessuna compatibilità delle applicazioni emulate qualificata.
- Dopo l’installazione a caldo, DXGI elenca prima Microsoft Basic Render Driver e poi la GPU VirtIO. La prima esecuzione sul default è stata respinta con exit2 e nessun modulo Neptune: non è un risultato sulla candidata. Il controllo permanente ora sceglie esplicitamente vendor/device VirtIO e usa lo stesso adattatore per A e B.
- Con l’adattatore esplicito: timeout20s, exit2. Un solo seguito diagnostico, stessa candidata e solo messaggi di avanzamento, conferma il blocco alla creazione di A; non raggiunti Wait, Clear/Copy o Signal. Non acquisita una lista completa dei moduli del processo bloccato. Un campionamento host successivo al primo timeout mostra soltanto il worker in ricezione: non identifica la causa del blocco.
- Certificato di sviluppo, modalità test e Secure Boot modificato sono confinati al clone. La ricetta e gli adattamenti di compilazione restano nel QA privato; non è fornito un installer o builder qualificato.

Anche il successivo arresto ACPI del clone non si completa entro60s. Interrotta solo la copia verificata, conservata offline e annotata come arresto non pulito; ordinario spento e invariato. Non attribuita una causa unica a questo ulteriore limite.

Un ultimo avvio diretto della stessa58004, senza modifiche e senza ripetere la prova fence, registra anche errori host sul ring: dimensione comando maggiore del buffer, poi status/tail non zero alla creazione del ring e fallimento del contesto. Il bridge non si ristabilisce entro l’ultima osservazione. Questi dati non isolano ancora la causa fra build, inizializzazione e modifica candidata.

Il successivo problema concreto è l’inizializzazione del dispositivo nel percorso utente, prima della verifica delle fence. Non cambiare Windows o promuovere il pacchetto sulla base del solo KMD caricato. Vedere `docs/VERIFICATION.md` per tentativi, evidenze e limiti.

Le patch sono state controllate mediante applicazione inversa sui sorgenti della candidata compilata. Dischi, variabili UEFI, TPM, certificati, binari, media e log rimangono fuori Git. Nessun cambio di driver o protezioni nella VM ordinaria; nessuna promozione del runtime.

## Seguito autorizzato del24 ottobre: inizializzazione isolata

L’utente ha chiesto nuovamente di proseguire. Confronto nello stesso clone: medesimo codice kernel nativo, DLL ufficiali v0.4; poi DLL ricompilata con scheduling disattivato; infine attivato nel solo processo di verifica.

Il primo pacchetto di confronto, INF58005/SYS58004/DLL58000, è stato installato ma rifiutato con problema31/`0xC0000182`, anche dopo un riavvio effettivo. La risorsa VERSIONINFO esisteva: nessuna nuova attribuzione alla sua assenza. Uniformati file/product version a58000 e INF, mantenendo le sezioni eseguibili del SYS byte per byte identiche, rifatti firma/catalogo e installazione forzata tramite API Windows nella copia: problema0/Running. [Microsoft richiede versioni coerenti fra INF, SYS e DLL](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/wddm-2-1-features#driver-versioning). I due aggiornamenti di pacchetto differiscono anche per il metodo di installazione; il confronto non isola da solo ogni controllo interno del loader.

SYS firmato coerente: `e0929b8c505fc6f5e0182773d762653109da9d9f41bd9fb2150bb3eea52c3dbf`. Con DLL originali `cf7cd403a6b8`/`b62f463ec4e4`, creazione/rilascio di un device esplicitamente VirtIO completati, feature level11.0, hash letti mentre il device è vivo. Arresto ACPI regolare e checkpoint offline223840Z conservati prima della successiva sostituzione.

La nuova DLL ARM64 nativa `155bd647c09394fab4f99d451afa8b95aec6adc6ef2952f143e1fd41a2e9cd17` crea/rilascia il dispositivo con modifica disattivata. Solo `PERP_DRIVER_SCHEDULE_TRIAL=1`, senza multi_ring, produce E_FAIL durante l’inizializzazione; con `NPT_PERF=multi_ring` termina. I messaggi `PERP_DRIVER_INIT_TRACE=1` sono circoscritti alle fasi iniziali; la variante diagnostica `d9ba6f38603c8677198160a8268d21c98c472c6cc628bfeff13aa03d4d5eb2a5` registra inoltre soltanto i primi12invii per dispositivo. La patch include questa osservabilità opt-in e il gating per processo. Le varianti differiscono per diagnostica, non per la logica di ordinamento candidata.

Il controllo fence completo sul pacchetto155b restituisce Wait CPU0,1771ms, query già completata prima del segnale, Map3,5919ms e tutti4096pixel `ff336699` con fence ancora0. La variante diagnostica conferma invii accettati (`hr=0`) su distinti contesti runtime per A/B e sul medesimo contesto Neptune con ring di autorizzazione distinti. Il successivo controllo serve soltanto a correlare eventi Wait/invio di Windows; nessuna finestra reale qualificata sulla candidata, nessuna promozione.

Questo supera il precedente blocco di setup, senza risolvere le fence né spiegare da solo i vecchi errori del ring al boot globale. Non attivare la modifica in DWM o a livello macchina, non ricominciare una matrice di boot o cambiare edizione Windows. Evidenze e media rimangono in `QA/selfsigned-start-gate-20261023/followup-init-20261024`, fuori Git.

La traccia DxgKrnl delimitata registra tre contesti del processo di controllo (trasporto Neptune interno, runtime A e runtime B), invii64byte sul contesto A e il Signal successivo su B. Il primo export XML è stato troncato: scartato e sostituito da estrazioni strutturate complete. Gli eventi estratti non bastano a dichiarare individuato il punto in cui viene persa la dipendenza Wait.

È stata verificata un’ipotesi ulteriore precisa: creazione tramite `D3DWDDM2_0DDI_CORELAYER_DEVICECALLBACKS.pfnCreateContextVirtualCb`, che dispone di ContextTypeFlags, al posto del callback KT generico. Con selettoreALL0 (`ec41df2661a5`) il dispositivo si crea ma il Wait resta violato; anche con maschera esplicita3D/COMPUTE/COPY (`2fa0f89bc6b5`) query e pixel precedono il Signal. Entrambi i tentativi sono conservati nel QA e rimossi dalla patch mantenuta: nessuna correzione verificata su quel confine. La sola differenza di API non dimostra la causa.

I raccoglitori privati di questi seguiti escono0 quando l’esecuzione termina, anche quando la semantica è errata: `fence-outcomes.json` distingue esecuzione riuscita da esito di ordinamento1 per tutte e quattro le DLL provate. Il controllo pubblico esistente continua a distinguere questi esiti.

Chiusura del seguito: arresto ACPI regolare, checkpoint225426Z del tentativo finale conservato; frontend privato chiuso, zero processi della copia e ripristino offline del controllo223840Z. Copia ora spenta e recuperabile, nessuna attivazione globale della candidata. App ordinaria SHA70e1691ac09f e firma profonda/stretta riconfermati invariati, ordinario lasciato spento come all’inizio. Il risultato utile di questo seguito è una catena di build/caricamento/inizializzazione interpretabile e un esperimento isolato per processo; la correzione dell’ordinamento resta da progettare sul confine effettivamente osservato. Nessun altro boot o cambio di Windows giustificato da questi risultati.
