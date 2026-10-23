# Esperimento di avvio dei comandi sotto lo scheduler Windows

**Candidata non qualificata e non integrata nel prodotto.** Dopo l’autorizzazione alla prova isolata e il successivo «continua pure», il KMD auto-firmato ora si carica nel clone: versione `100.6.101.58004`, dispositivo con problema 0, servizio Running e firma Valid. La prova sul relativo adattatore hardware scade però dopo 20 secondi durante `D3D11CreateDevice` del primo dispositivo, prima di accodare il Wait. Nessun risultato qualificato sull’ordinamento delle fence, nessun confronto nell’app e nessun miglioramento grafico dimostrato.

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
