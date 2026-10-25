# Perpendicular — Carbone e cobalto

Direzione scelta dall’utente il 25 ottobre 2026: palette standard e sobria, basata su carbone e cobalto. Il disegno mantiene la forma, le proporzioni e l’inclinazione di 45° antiorari del simbolo scelto dall’utente. Nell’icona i due tratti sono asset distinti, entrambi cobalto: la base copre la fine dello stelo per ricomporre il segno continuo. Entrambi sono gruppi indipendenti con Liquid Glass, traslucenza e ombra regolabili separatamente in Icon Composer.

L'icona è integrata dal confezionamento dell'app0.2.2: Icon Composer viene compilato in Assets.car conservando i due gruppi; l'ICNS statico copre il percorso precedente e il PNG compare nel launcher. La palette generale resta una guida: questo aggiornamento applica il marchio, non cambia tutti i colori dell'interfaccia.

## Palette

| Colore | sRGB | Uso |
| --- | --- | --- |
| Carbone | `#151A23` | Fondo dell’icona e tema scuro |
| Carbone rialzato | `#202632` | Superfici scure secondarie |
| Cobalto | `#4E7CFE` | Accento visivo dell’icona |
| Cobalto profondo | `#2459D6` | Azioni e link nel tema chiaro |
| Perla cobalto | `#B8CAFF` | Accento leggibile sulle superfici scure |
| Carta | `#F4F6F9` | Sfondo chiaro |
| Inchiostro | `#171C26` | Testo principale chiaro |
| Grigio | `#687386` | Testo secondario |

Il cobalto è l’unico accento cromatico dell’interfaccia; superfici e testo restano neutri. Usare il tono profondo per testo e controlli su sfondo chiaro. Il rapporto di contrasto dei materiali trasparenti va verificato nel contesto reale dell’app.

## Icona in Icon Composer

- `Perpendicular.icon` è il documento nativo. Lo sfondo carbone è separato dai gruppi dei tratti.
- `Assets/base.svg` e `Assets/stem.svg` sono i due tracciati indipendenti. L’ordine dei gruppi sovrappone la base alla fine dello stelo, nascondendo la giunzione.
- Entrambi i gruppi hanno Liquid Glass e ombra indipendenti, modificabili nell’Inspector di Icon Composer.
- I tratti mantengono l’inclinazione di 45° e terminali arrotondati. `symbol.svg` è un riferimento vettoriale unito.
- `palette.json` conserva i colori e i ruoli semantici per tema chiaro/scuro.

## Esportazione

Dalla radice del progetto, `swift design/brand/export.swift` usa il renderer ufficiale di Icon Composer installato con Xcode, generazione 27. Gli output vengono creati in `.build/brand`: PNG principale/scuro, ICNS, palette macOS CLR e tavola di presentazione. L’ICNS è statico; il materiale dinamico rimane nel documento Icon Composer.

`scripts/build-macos.sh` richiama `scripts/package-app-icon.sh`: compila il documento con actool, include Assets.car, ICNS e BrandMark.png nel bundle e allinea CFBundleIconFile/CFBundleIconName all'output del compilatore prima della firma. I prodotti generati rimangono fuori Git.
