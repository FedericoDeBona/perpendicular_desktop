# Prima installazione di Perpendicular

Candidata in sviluppo, non ancora una release pronta. Stato e criterio di completamento: [TODO-026](../docs/TODO.md#todo-026--prima-installazione-automatica-e-release-github); prove e fallimenti: [VERIFICATION](../docs/VERIFICATION.md#14-novembre--prima-installazione-automatica-da-iso).

Il primo avvio deve richiedere soltanto ISO/licenza e permessi macOS, quindi creare una nuova Windows, installare i componenti e aprire lo schermo pronto. Non si distribuisce Windows e non si importa una VM già installata. Seamless rimane disabilitato.

La prima edizione supportata dal lettore ISO è Windows 11 IoT Enterprise LTSC 2024 ARM64, `IoTEnterpriseS`, build almeno26100. Il lettore WIM seleziona l'indice dai metadati: nella ISO di prova è2, non1. Altre edizioni vengono rifiutate prima di creare un disco. Per il momento la prova completa non è riuscita: il firmware raggiunge il boot ma Setup non ha ancora scritto nel disco nuovo. Non presentare una UI di attesa o un pacchetto firmato come prova del completamento.

## Dipendenze portabili

`scripts/package-first-run.py` confeziona firmware e driver in un'app separata, dopo i sette controlli del runtime corrente. Non legge dischi, variabili EFI, TPM o credenziali da una VM. Il codice firmware e le variabili Microsoft iniziali provengono dal pacchetto Debian pubblico fissato in `requirements.json`, con licenza inclusa. I relativi hash non autorizzano a usare variabili di un'altra macchina.

```sh
python3 scripts/package-first-run.py \
  --app /percorso/Perpendicular.app \
  --graphics /percorso/driver-originale-v04/Graphics \
  --network /percorso/NetKVM \
  --memory /percorso/con/Balloon-e-VioMem \
  --probes /percorso/probe-compilati
```

Gli input devono corrispondere esattamente a `guest/graphics-driver.json`, `guest/network-driver.json` e `guest/memory-drivers.json`; nessun pin viene aggiornato per accettare un file locale. Il driver originale v0.4 serve come base agli installer video/OpenGL già condivisi; il pacchetto ordinario contiene poi gli aggiornamenti video/x86 e il kernel firmato v0.5. Gli archivi originali e le ricette sono descritti nei README grafica e memoria. Per NetKVM il `Readme.md` originale corrisponde a `NetKVM/Documentation/Readme.md` del repository virtio-win, con terminatori CRLF; anche il documento viene verificato per hash.

L'app prepara i dati sotto la propria cartella privata, genera UUID/MAC/porta/token/password distinti e crea un disco qcow2 vuoto da80GiB. La ISO rimane sul Mac dell'utente. Il preparatore verifica il catalogo El Torito e l'extent EFI, poi usa il boot Microsoft no-prompt incluso nella ISO in una copia privata; il file originale non viene modificato. La risposta unattended e i segreti temporanei non entrano nel repository o nella release; l'installer deve eliminarli dopo il riavvio verificato. La fase di predisposizione parziale e l'integrazione OpenGL/cartelle richiedono ancora completamento e prova reale prima di pubblicare.

La ricetta `build-first-run-probes.py` ricompila il piccolo controllo WGL esistente per ARM64 con il toolchain Windows già usato dal progetto. È un controllo di installazione, non una qualifica generale o un benchmark. La variante x64 richiede le corrispondenti librerie SDK, non presenti nel cache locale verificato inizialmente.

## Distribuzione scelta dall'utente

Nessun account Apple Developer e nessuna notarizzazione: la release userà la firma locale/ad-hoc necessaria ai binari ed esporrà l'avviso di macOS. L'utente autorizzerà l'apertura in Privacy e sicurezza. Non promettere una release notarizzata o un avvio senza autorizzazione. Il pacchetto finale deve rimuovere `PerpendicularMachineDirectory`, `LSEnvironment` e ogni configurazione privata di prova, includere gli avvisi delle dipendenze e accompagnare ZIP e checksum. Il caricamento di una release è ancora da fare, dopo la verifica completa.

## Riferimenti del percorso unattended

- [Windows Setup Automation Overview](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-automation-overview?view=windows-11).
- [RunSynchronous in specialize, eseguito come SYSTEM](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous).
- [AutoLogon e creazione dell'account](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon).
- [AcceptEula](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-userdata-accepteula): l'app richiede il consenso prima di generare la risposta. Consenso esplicito ricevuto per la prova corrente.
- [Firmware AAVMF Debian](https://sources.debian.org/src/edk2/2022.11-6%2Bdeb12u2/debian/qemu-efi-aarch64.README.Debian/): distinguere modello pulito con chiavi Microsoft e stato EFI privato di una macchina.
