# Monitor del desktop corrente

Il desktop corrente usa un solo monitor virtuale. Windows segue la finestra Mac e il fullscreen attraverso la [sequenza host di resize](../driver/custom-resolution.md), con driver ufficiale e protezioni attive. Non cambiare la cornice Mac per adattarla a un modo Windows predefinito.

`HostDisplay` legge dimensioni fisiche CoreGraphics e UUID del monitor scelto. Il runtime che dichiara `primary_monitor_metadata=1` riceve questi metadati all’avvio. `primary-monitor.patch` conserva dimensioni fisiche, origine e frequenza di `QemuUIInfo` quando cambia il raster; QEMU annuncia i millimetri nell’EDID e deriva dall’UUID un seriale numerico a 32 bit. Il seriale non conserva tutto l’UUID né garantisce assenza di collisioni.

I millimetri EDID non impongono le preferenze DPI Windows. La risoluzione e la scala vanno lette nel guest prima di usare una trasformazione condivisa. Non sono implementati da questa patch hotplug, monitor N+1 o supporto completo fra scale diverse.

`consumer-demand.patch` conserva una sola richiesta scanout pendente quando il consumer è assente o non ha slot, e richiede un’immagine fresca al ritorno della capacità. Pump, ACK e lease continuano a essere gestiti; il reset scarta la domanda della vecchia selezione. Non controlla il lavoro di rendering Windows né abilita catture individuali.

`scripts/rebuild-native-monitor.py` e `scripts/rebuild-local-graphics.py` sono adattatori di basi specifiche, con input e hash vincolati. Producono copie private, non qualificano il risultato nell’app e non sono una ricostruzione universale del QEMU attuale. Non eseguirli sulla base corrente presumendo di preservarne automaticamente tutte le patch. Il runtime effettivamente in uso e i relativi hash sono nel [piano](../../docs/RESTART_PLAN.md).

I controlli C degli header e della domanda del consumer verificano logica circoscritta, senza avviare Windows. Le vecchie directory `.build/native-monitor-*`, i tentativi di ricompilazione e le geometrie superate sono rimossi dalle istruzioni operative; risultati, errori e verifiche guest rimangono nel [diario](../../docs/VERIFICATION.md) e nella [guida storica](https://github.com/FedericoDeBona/perpendicular_desktop/blob/3589194/graphics/monitor/README.md).
