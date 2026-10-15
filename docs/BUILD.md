# Compilazione e installazione su iPad

## Requisiti

- Mac con **Xcode 16 o successivo** (consigliato Xcode 26). Il progetto usa le cartelle sincronizzate (formato `objectVersion 77`), introdotte in Xcode 16.
- iPad con **iPadOS 17.0 o successivo**. Alcune funzioni usano API più recenti con controllo di disponibilità: `SpeechAnalyzer` (iPadOS 26) e `AVAudioFile.close()` / nuovo export (iPadOS 18).
- Un Apple ID (gratuito o Apple Developer Program) per firmare l'app.

## 1. Aprire il progetto

```bash
git clone <questo repository>
cd OpenNote
open QuadernoAI.xcodeproj
```

Xcode risolve automaticamente il pacchetto locale `Packages/QuadernoCore`.

Se il progetto non si aprisse (ad esempio con una versione di Xcode precedente), ci sono due alternative:

```bash
python3 tools/generate_xcodeproj.py   # rigenera QuadernoAI.xcodeproj
# oppure, con XcodeGen installato:
xcodegen generate
```

## 2. Firma

1. Seleziona il progetto **QuadernoAI** → target **QuadernoAI** → *Signing & Capabilities*.
2. Imposta il tuo **Team**.
3. Se `it.quadernoai.app` non è disponibile, cambia il **Bundle Identifier** (ad esempio `com.tuonome.quadernoai`). L'identificatore del BGTask in `Info.plist` lo segue automaticamente.
4. Le capacità necessarie sono già nell'`Info.plist`: *Background Modes → Audio* e *Background processing*. Non servono entitlements aggiuntivi.

## 3. Prima compilazione

Prodotto → Build (⌘B), destinazione «iPad (simulatore)» o il tuo iPad.

> L'app è stata scritta senza poterla compilare: aspettati qualche errore di compilazione da correggere al primo build. Il nucleo `QuadernoCore` invece compila ed è testato.

Le aree con API più recenti, da controllare per prime se il compilatore segnala problemi:

- `App/AI/AppleSpeechTranscriptionProvider.swift`: API `SpeechAnalyzer` di iPadOS 26, confrontate con la sessione WWDC25. Se servisse, il ramo iPadOS 26 si può disattivare temporaneamente lasciando solo `SFSpeechRecognizer`.
- `Packages/QuadernoOnDevice` (FluidAudio 0.17.7 e WhisperKit 1.1.1, scaricati da Xcode al primo build): API verificate sui sorgenti dei tag, ma il pacchetto non è mai stato compilato (CoreML non esiste su Linux). Se un'API fosse cambiata, gli unici punti di contatto sono `FluidAudioEngine.swift` e `WhisperKitEngine.swift`.
- `App/Recording/SegmentedAudioWriter.swift` (`AVAudioFile.close()`, iPadOS 18) e `App/Recording/AudioConsolidator.swift` (`AVAssetExportSession.export(to:as:)`, iPadOS 18), entrambi con un'alternativa per iPadOS 17.

## 4. Test

- **Nucleo** (anche senza Xcode): `cd Packages/QuadernoCore && swift test`
- **App + nucleo in Xcode**: Prodotto → Test (⌘U). Lo schema condiviso include `QuadernoAITests` e `QuadernoCoreTests`. I test dell'app usano un database in memoria, audio sintetico e nessuna chiamata di rete.
- **Backend**: `cd Backend && python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/python -m pytest`. Il test end-to-end richiede `swift build -c release --product quaderno-worker` e ffmpeg.

## 5. Installare sull'iPad

1. Collega l'iPad al Mac via USB o in rete e accetta «Autorizza questo computer».
2. Su iPad: Impostazioni → Privacy e sicurezza → **Modalità sviluppatore** → attiva e riavvia (richiesto da iPadOS 16+).
3. In Xcode seleziona l'iPad come destinazione e premi **Run** (⌘R).
4. Con un Apple ID gratuito, al primo avvio vai su Impostazioni → Generali → VPN e gestione dispositivi → autorizza il tuo profilo sviluppatore. Il certificato gratuito scade dopo 7 giorni: reinstalla da Xcode.
5. Al primo avvio della registrazione iPadOS chiede il permesso per il microfono.

## 6. Verificare la registrazione in background

1. Profilo Release consigliato per misure realistiche: Product → Scheme → Edit Scheme → Run → Build Configuration: Release.
2. Avvia una registrazione, blocca l'iPad, attendi, sbloccalo. L'indicatore arancione del microfono e il banner REC devono restare attivi e la durata deve includere il tempo a schermo bloccato.
3. Segui l'intera checklist in [`MANUAL_TEST_CHECKLIST.md`](MANUAL_TEST_CHECKLIST.md).

## 7. Misurare consumo ed energia

- Xcode → Product → **Profile** (⌘I) → *Energy Log* (sul dispositivo), *Time Profiler*, *Allocations*.
- Scenario: 30 minuti di registrazione a schermo bloccato, poi 30 minuti di scrittura con registrazione attiva. Annota l'impatto energetico medio e le punte di CPU.
- Atteso dal progetto (da verificare): durante la registrazione la CPU resta vicina allo zero (tap ogni ~90 ms, codifica AAC di sistema) e a schermo bloccato non c'è rendering. Il banner aggiorna la durata una volta al secondo e solo quando è visibile.

Non vengono dichiarati valori di autonomia: vanno misurati su dispositivo.

## 8. Distribuzione (fase successiva)

- Archivio: Product → Archive, poi distribuzione TestFlight/App Store.
- Prima della pubblicazione: completare l'informativa privacy (il manifesto `PrivacyInfo.xcprivacy` è incluso), le schermate, la localizzazione in inglese e le prove su più modelli di iPad.
