# Ricerca preliminare (ottobre 2026)

## App di riferimento

**Whisper Notes** (Yeonni Lee, iOS/macOS): trascrizione interamente sul dispositivo, importazione di file audio e video, export con timestamp, acquisto una tantum. AppleVis la descrive come pienamente accessibile con VoiceOver, veloce e accurata; l'unico difetto segnalato è l'export che include sempre link e timestamp, senza opzione per toglierli. Elementi ripresi in Quaderno AI:

- trascrizione sul dispositivo come scelta esplicita (Apple Speech, nessun invio dell'audio);
- importazione anche di video MP4/MOV (si estrae solo la traccia audio);
- export della trascrizione sia con tempi sia come testo semplice (l'opzione che mancava a Whisper Notes);
- etichette di accessibilità su controlli e stati.

Con lo stesso nome esistono altre app (*WhisperNotes: Offline AI*, *Whisper Notes – AI Note Taker*): non vanno confuse.

**CollaNote, Goodnotes, Notability** (riferimento per l'esperienza di scrittura): libreria a copertine, pagine con modelli, barra degli strumenti PencilKit, registrazione collegata agli appunti (Notability). Quaderno AI ne riprende l'organizzazione, non grafica né risorse. La sincronizzazione audio-appunti è implementata a livello di pagina; quella per singolo tratto è una fase successiva.

## API verificate

- **OpenAI – File transcription** (documentazione ufficiale): `gpt-transcribe` è il modello consigliato per file completi, con `prompt`, `keywords` e `languages` (che sostituisce `language`). Risposta `{text, languages}` senza timestamp. `gpt-4o-transcribe-diarize` usa `diarized_json`, richiede `chunking_strategy` oltre i 30 s e non accetta prompt. `whisper-1` è l'unico con timestamp di segmento e parola. Limite di 25 MB per file; formati mp3, mp4, mpeg, mpga, m4a, wav, webm. Le keyword devono stare su una riga, senza `<` né `>`.
- **OpenAI – Cookbook di migrazione a GPT-Transcribe:** keywords e languages compaiono via `extra_body`. La codifica multipart `keywords[]` / `languages[]` usata dall'app segue la convenzione dei campi array (`timestamp_granularities[]`) ed è **da confermare** con una chiave reale.
- **Segnalazioni della community OpenAI:** `chunking_strategy: auto` può allucinare su chunk solo rumore (l'app filtra le frasi tipiche e le riporta); le etichette degli interlocutori non sono coerenti fra chunk diversi.
- **Anthropic Messages API:** default `claude-opus-5-5`, ragionamento adattivo predefinito (niente `budget_tokens`), `output_config.effort`, output strutturato `output_config.format`, streaming SSE, fallback lato server `fallbacks: "default"` con beta `server-side-fallback-2026-07-01`, nessun prefill dell'assistente.
- **Apple SpeechAnalyzer (WWDC25, sessione 277):** `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`, `SpeechTranscriber.supportedLocales`, `AssetInventory.assetInstallationRequest(supporting:)`, `SpeechAnalyzer(modules:)`, `analyzeSequence(from:)` + `finalizeAndFinish(through:)`. Pensato per audio lungo e voci distanti; disponibile da iPadOS 26.

## Fonti

- [Whisper Notes – App Store](https://apps.apple.com/us/app/whisper-notes-speech-to-text/id6447090616)
- [Whisper Notes – recensione AppleVis](https://applevis.com/comment/212645)
- [OpenAI – File transcription](https://developers.openai.com/api/docs/guides/speech-to-text)
- [OpenAI Cookbook – Migrating from Whisper to GPT-Transcribe](https://developers.openai.com/cookbook/examples/migrating_from_whisper_to_gpt_transcribe)
- [OpenAI Community – chunking_strategy per i modelli di diarizzazione](https://community.openai.com/t/gpt-4o-transcribe-diarize-returns-chunking-strategy-is-required-any-working-example-or-schema/1364231/4)
- [OpenAI Community – identità degli interlocutori fra chunk](https://community.openai.com/t/best-practices-for-maintaining-speaker-identity-across-chunks-with-gpt-4o-transcribe-diarize/1364126)
- [Apple WWDC25 – Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
