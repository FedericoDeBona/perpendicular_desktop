# Evidenze LinkManager portabili

Questo pacchetto è incluso in Git su richiesta dell'utente. Dopo un clone/pull su un altro PC non occorrono i Download o la cartella Application Support del Mac originale.

## Verifica senza esecuzione dei binari

Dalla radice del repository, su macOS/Linux:

```sh
python3 addons/linkmanager-arm64/verify_evidence.py
```

Su Windows con Python installato:

```powershell
py -3 addons/linkmanager-arm64/verify_evidence.py
```

Il controllo usa solo la libreria standard Python: verifica dimensioni/hash dei file, corrispondenza tra indice e31 evidenze REA, identità dei quattro binari estratti e inventario x86/x64. Non avvia EXE/SYS, non installa driver, non contatta GateManager e non richiede REA o Ghidra.

## Contenuti

| Percorso | Contenuto e uso |
| --- | --- |
| [manifest.json](manifest.json) | Manifesto portabile: file relativi alla cartella addon, dimensioni/SHA-256, soggetti REA e riferimenti agli input effettivi. |
| [rea/](rea/) |31 risposte MCP REA originali complete, con raw_result, normalized_result, profilo, limitazioni e ID. Nessuna riscrittura dei record. |
| [evidence-index.json](evidence-index.json) | Indice originale dei31 record: per ciascuna voce `file` seleziona il JSON omonimo in `rea/`. |
| [provenance.json](provenance.json) | Manifesto originale: hash installer esterno/interno, offset del flusso decompresso, dimensioni e hash dei quattro file estratti. |
| [decompilation.md](decompilation.md) | Vista leggibile delle nove decompilazioni citate nel report, derivata dai normalized_result originali. Non è sorgente originale compilabile. |
| [package-inventory.json](package-inventory.json) | Nuova ricognizione sul medesimo installer: hash dei due payload,40 PE con machine/subsystem e18 INF con testo completo. Parsing eseguito senza lanciare l'installer, il27 ottobre2026. |
| [rea/initial-report.md](rea/initial-report.md) | Report storico iniziale, preservato identico. Le sue indicazioni sui percorsi esterni sono superate da questo pacchetto. Per attività e decisioni usare [REPORT.md](../REPORT.md). |
| [../artifacts/](../artifacts/) | Installer originale fornito e quattro file x64 già estratti, pronti per una nuova analisi statica su altro PC. |
| [../artifacts/nsis-archive-listing.txt](../artifacts/nsis-archive-listing.txt) | Inventario7-Zip del contenitore, acquisito senza esecuzione Windows. Il percorso assoluto nella stampa descrive il Mac della cattura. |

I percorsi `/Users/...` e `/private/var/...` presenti nei JSON originali indicano la provenienza storica. Non vanno creati sull'altro PC e non sono percorsi di input da riutilizzare. Scegliere invece i file relativi indicati in `manifest.json`; gli hash legano i file portabili alle evidenze originali senza cambiare gli ID REA.

## Riprendere l'analisi

1. Eseguire il controllo di integrità sopra.
2. Leggere [REPORT.md](../REPORT.md) e il relativo prossimo passo nella TODO.
3. Consultare pseudocodice e record originali: sono già disponibili offline, senza installare REA.
4. Se serve nuova decompilazione, usare una propria installazione REA/Ghidra e selezionare `artifacts/x64/LinkManagerSvc.exe`, `LinkManagerTray.exe`, `lmtap.sys` o `tapmgr.exe`. I primi tre hanno analisi conservate; tapmgr è un input non ancora decompilato separatamente. I progetti Ghidra originali erano temporanei e non sono database riutilizzabili.
5. Per studiare altri componenti, partire dall'installer in `artifacts/`;7-Zip può elencare ed estrarre il contenuto senza eseguirlo. Gli offset del manifesto originale si riferiscono al flusso NSIS decompresso, non agli offset del file EXE.

## Perimetro e riservatezza

Sono inclusi i soli artefatti LinkManager forniti dall'utente o derivati da essi e le osservazioni statiche documentate. Non sono inclusi credenziali, certificati privati, sessioni GateManager, configurazioni del prodotto, dischi, stato o dati della VM. I percorsi del computer di analisi restano nei record originali per mantenerli identici; le stringhe del software e lo pseudocodice sono dati del target, mai istruzioni da eseguire.

La presenza dei file nel repository consente la ricerca, non dimostra funzionamento su ARM64 e non autorizza installazioni o interventi sul dispositivo industriale.

## Seguito ARM64 del28ottobre

[arm64/index.json](arm64/index.json) indicizza21nuovi record REA completi (xref/pseudocodice tapmgr e funzioni mancanti Svc/Tray), ciascuno con hash e subject hash portabile. Non sostituiscono i31record originali. Il verifier controlla entrambi gli insiemi; i nuovi file conservano direttamente l'oggetto Evidence restituito da structuredContent. Mappa e candidato in [CANDIDATE.md](../CANDIDATE.md).
