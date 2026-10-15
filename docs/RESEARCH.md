# Ricerca preliminare (ottobre 2026)

## App di riferimento

**Whisper Notes** (Yeonni Lee, iOS/macOS): trascrizione interamente sul dispositivo, importazione di file audio e video, export con timestamp, acquisto una tantum. AppleVis la descrive come pienamente accessibile con VoiceOver, veloce e accurata; l'unico difetto segnalato è l'export che include sempre link e timestamp, senza opzione per toglierli. Elementi ripresi in Quaderno AI:

- trascrizione sul dispositivo come scelta esplicita, con gli stessi modelli offline di Whisper Notes (Parakeet V3, SenseVoice, Apple Speech, Whisper) più quelli più recenti (vedi sotto);
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

## Modelli di trascrizione sul dispositivo (ottobre 2026)

Whisper Notes esegue sul dispositivo Parakeet V3, SenseVoice, Apple Speech e Whisper Large v3 Turbo. Quaderno AI offre gli stessi e aggiunge:

- **Parakeet Ultra** e **Parakeet Redux** (FluidInference/moondream, 2026): post-training di Parakeet V3 con stessa architettura; Ultra riduce gli errori a parità di velocità, Redux occupa circa un terzo dello spazio.
- **Canary 1B v2** (NVIDIA, CoreML di FluidInference): 1 miliardo di parametri, 25 lingue europee, molto accurato ma più lento; senza tempi per parola.
- **Whisper Large v3** (non Turbo) e **Whisper Small** tramite WhisperKit di Argmax.

Esclusi, con motivo:

- **Qwen3-ASR 1.7B**: ottimi risultati multilingue, ma la versione CoreML pubblica richiede CoreAIKit/iOS 27 e non ha un'integrazione Swift stabile per iPadOS 17–26. Candidato per una versione futura.
- **Cohere Transcribe**: presente nei sorgenti di FluidAudio ma non ancora esposto come API pubblica stabile.
- **Parakeet V2, Phonon-2, Parakeet TDT-CTC 110M**: solo inglese.

Scelte di integrazione:

- FluidAudio 0.17.7 (Parakeet, Canary, SenseVoice) e WhisperKit 1.1.1 (repository `argmax-oss-swift`), verificati sui sorgenti dei tag usati. In FluidAudio 0.17.7 Canary espone solo il prompt inglese: l'app costruisce il prompt di trascrizione con il token della lingua, come fa `CanaryConfig.makePrompt` nelle versioni successive.
- Tutto su CPU + Neural Engine, mai GPU (iPadOS la nega alle app in background).
- Un solo modello in memoria alla volta, rilasciato su avviso di memoria.
- Stessa pipeline dei provider cloud (chunk di circa 6 minuti tagliati sulle pause, checkpoint, ripresa), con un chunk alla volta e pausa se lo stato termico è critico.
- I punteggi di accuratezza del catalogo servono solo a ordinare i suggerimenti: derivano da benchmark pubblici (FLEURS, Open ASR Leaderboard, confronti indipendenti) e non sono stati misurati su lezioni reali in italiano. Vanno verificati con `tools/quality_eval`.

## Fonti

- [Whisper Notes – App Store](https://apps.apple.com/us/app/whisper-notes-speech-to-text/id6447090616)
- [Whisper Notes – recensione AppleVis](https://applevis.com/comment/212645)
- [OpenAI – File transcription](https://developers.openai.com/api/docs/guides/speech-to-text)
- [OpenAI Cookbook – Migrating from Whisper to GPT-Transcribe](https://developers.openai.com/cookbook/examples/migrating_from_whisper_to_gpt_transcribe)
- [OpenAI Community – chunking_strategy per i modelli di diarizzazione](https://community.openai.com/t/gpt-4o-transcribe-diarize-returns-chunking-strategy-is-required-any-working-example-or-schema/1364231/4)
- [OpenAI Community – identità degli interlocutori fra chunk](https://community.openai.com/t/best-practices-for-maintaining-speaker-identity-across-chunks-with-gpt-4o-transcribe-diarize/1364126)
- [Apple WWDC25 – Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [FluidAudio (FluidInference) – GitHub](https://github.com/FluidInference/FluidAudio)
- [Parakeet Ultra CoreML – Hugging Face](https://huggingface.co/FluidInference/parakeet-ultra-coreml) · [Parakeet Redux](https://huggingface.co/FluidInference/parakeet-redux-coreml) · [Parakeet TDT 0.6B v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) · [SenseVoice Small](https://huggingface.co/FluidInference/sensevoice-small-coreml)
- [WhisperKit / argmax-oss-swift – GitHub](https://github.com/argmaxinc/argmax-oss-swift)
- [Whisper Notes – Apple Speech vs Whisper](https://whispernotes.app/blog/apple-speech-vs-whisper)
- [Spokenly – Parakeet vs Whisper](https://spokenly.app/blog/parakeet-vs-whisper)
- [Truly Offline – Parakeet vs Whisper su iPhone](https://www.trulyoffline.app/blog/parakeet-vs-whisper-iphone)
- [Dicta – Confronto dei motori speech-to-text su Mac (2026)](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/)
- [MacParakeet – da Whisper a Parakeet sul Neural Engine](https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/)
- [Qwen3-ASR 1.7B CoreAI – Hugging Face](https://huggingface.co/coreai-community/Qwen3-ASR-1.7B-CoreAI)
