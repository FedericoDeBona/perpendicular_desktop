# Esperimenti ritirati dal ramo attivo

Il25ottobre2026 l’utente ha scelto la base desktop con driver ufficiale e protezioni attive e ha richiesto di eliminare vecchie prove, codice e dischi VM. Il lavoro prosegue su `main`. Nessun nuovo ramo o archivio di dischi è stato creato.

Le prove e i fallimenti restano in [VERIFICATION.md](VERIFICATION.md). I sorgenti rimossi sono recuperabili dalla revisione completa [d5c02e3](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3), precedente alla pulizia:

| Prova ritirata | Sorgente storico |
| --- | --- |
| IVSHMEM, full frame, compressione e dirty region | [experimental/ivshmem](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/experimental/ivshmem) |
| WGC verso GPU: overlay guest/frontend e diagnostica del prototipo | [experimental/wgc-gpu](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/experimental/wgc-gpu) |
| RDP e riferimento DOD/2D | [experimental](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/experimental) |
| KMD custom resize, scheduler/UMD/completion/compositore test-signed | [graphics/driver](https://github.com/FedericoDeBona/perpendicular_desktop/tree/d5c02e3/graphics/driver) |
| Gate host D3D11 candidato e controlli sintetici delle fence | [renderer](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/graphics/renderer/experimental-d3d11-completion-gate.patch), [controllo](https://github.com/FedericoDeBona/perpendicular_desktop/blob/d5c02e3/scripts/check-graphics-fence-wait.py) |

Il renderer attuale contiene ancora l’export host introdotto durante WGC. Per non perdere i sorgenti di una parte realmente compilata, `wgc-export.inc`, `wgc-export-timing.patch` e la ricetta `scripts/rebuild-native-export.py` sono conservati accanto alle parti grafiche attive. La pulizia non ricompila né cambia il renderer; non rende attive le finestre individuali o il trasporto IVSHMEM.

I vecchi dischi e checkpoint rimossi non sono recuperabili da Git. Rimangono la VM attuale, quella ordinaria, la sorgente originaria e un checkpoint recente, descritti nel [piano corrente](RESTART_PLAN.md). Ricevute private, log e immagini compatti restano fuori dal repository. I vecchi percorsi nelle sezioni storiche del diario possono riferirsi a build o dischi ora eliminati: non sono istruzioni operative.
