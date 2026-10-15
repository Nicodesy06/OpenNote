# Quaderno AI

App nativa per iPadOS (SwiftUI, PencilKit, AVFoundation, SwiftData) che unisce, per lo studio universitario:

- **quaderni** da scrivere con Apple Pencil, organizzati per materia;
- **registrazione delle lezioni**, anche a schermo bloccato e mentre si scrive;
- **importazione** di registrazioni esistenti (M4A, MP3, WAV, AAC, MP4);
- **trascrizione** cloud (OpenAI `gpt-transcribe`) o **offline sul dispositivo** con il modello che preferisci: Parakeet Ultra/V3/Redux, Canary 1B v2, Whisper Large v3/Turbo/Small, SenseVoice, Apple Speech;
- **sbobinatura AI** integrale e verificata (Anthropic Claude o OpenAI), scritta come un testo universitario completo;
- **editor** delle sbobinature con versioni, rigenerazione per sezione, confronto con audio e trascrizione, export PDF/DOCX;
- **PDF e slide** annotabili con Apple Pencil, **glossario** della materia.

Sostituisce il flusso "registratore → trasferimento → trascrizione → ChatGPT/Claude → Word" con un'unica app.

> **Stato del progetto:** il codice è completo per tutte le fasi 1–7. Il nucleo logico e il backend sono stati **compilati e testati** (vedi sotto). L'app iPadOS **non è ancora stata compilata**: l'ambiente di sviluppo usato era Linux, senza Xcode. Va aperta in Xcode, corretta da eventuali errori di compilazione e provata su un iPad (vedi [`docs/BUILD.md`](docs/BUILD.md) e [`docs/MANUAL_TEST_CHECKLIST.md`](docs/MANUAL_TEST_CHECKLIST.md)).

## Struttura del repository

```
QuadernoAI.xcodeproj        Progetto Xcode (Xcode 16+, cartelle sincronizzate)
project.yml                 Alternativa per XcodeGen
Config/Info.plist           Permessi, modalità audio in background, tipi di documento
App/                        App iPadOS
  Models/                   Modelli SwiftData (schema versionato + piano di migrazione)
  Storage/                  File, Keychain, impostazioni, disegni, gestione contenuti
  Recording/                Registratore: AVAudioEngine, segmenti, manifest, recupero
  Playback/ Import/         Riproduzione, importazione audio e PDF
  AI/                       Provider, estrazione chunk, upload in background, coda dei lavori
  Export/                   Rendering Markdown, PDF di sbobinature, quaderni e PDF annotati
  Features/                 Interfaccia (libreria, materie, quaderni, registratore, sbobinature…)
  Resources/                Asset (icona), catalogo stringhe, manifesto privacy
AppTests/                   Test dell'app (simulatore/dispositivo)
Packages/QuadernoOnDevice/  Modelli di trascrizione sul dispositivo (FluidAudio, WhisperKit; solo Apple)
Packages/QuadernoCore/      Pacchetto Swift multipiattaforma (iPadOS, macOS, Linux)
  Sources/QuadernoCore/     Chunking, merge, client OpenAI/Anthropic, motore di sbobinatura,
                            prompt versionati, verifica, Markdown, export DOCX, client backend
  Sources/QuadernoWorker/   Worker CLI per il backend (ffmpeg + QuadernoCore)
  Tests/                    87 test (nessuna chiamata di rete reale)
Backend/                    Backend gestito (FastAPI) con lavori persistenti, Dockerfile, test
tools/                      Generatore del progetto Xcode, valutazione della qualità
docs/                       Compilazione, API, architettura, test manuali, ricerca
```

## Cosa è stato verificato davvero

| Verifica | Esito |
|---|---|
| `swift test` su QuadernoCore (Swift 6.1.2, Linux) | **87 test superati**: catalogo dei modelli sul dispositivo, chunking, deduplica, merge, client OpenAI/Anthropic (anche streaming SSE), motore di sbobinatura con provider simulati, verifica, Markdown, DOCX, client del backend, ffmpeg reale |
| DOCX generato aperto con `python-docx` | Titoli, elenchi, tabelle, immagini e citazioni riconosciuti |
| Backend (`pytest`) | **8 test superati**, compreso un **end-to-end** con worker Swift reale, audio reale tagliato da ffmpeg e provider HTTP simulati |
| `project.pbxproj` | Interpretato da un parser OpenStep indipendente, nessun riferimento pendente |
| Compilazione dell'app iPadOS | **Non eseguita** (manca Xcode) |
| Pacchetto `QuadernoOnDevice` | Manifest validato (`swift package dump-package`), sintassi controllata, API di FluidAudio 0.17.7 e WhisperKit 1.1.1 confrontate con i sorgenti dei tag. **Non compilato** (CoreML non esiste su Linux) e **nessun modello eseguito** |
| Test in `AppTests/` | **Non eseguiti** (richiedono il simulatore iOS) |
| Prove su iPad fisico | **Non eseguite** |
| Chiamate reali a OpenAI/Anthropic | **Non eseguite** (nessuna chiave nell'ambiente); i formati seguono la documentazione di ottobre 2026 |
| Build Docker del backend | **Non eseguita** |

I test hanno trovato e permesso di correggere bug reali: un deadlock nel backend, la regola della coda nella pianificazione dei chunk e un preambolo duplicato nell'unione delle parti di una sezione.

## Stato delle funzionalità

Legenda: **Completa** = implementata nel codice e coperta da test eseguiti o verificabile solo su dispositivo; **Da verificare** = implementata ma mai compilata né eseguita; **Parziale** = implementata con limiti dichiarati; **Non implementata**.

| Area | Funzionalità | Stato |
|---|---|---|
| Libreria | Materie (crea, modifica, colore, icona, archivio, eliminazione con conferma, ordinamento) | Da verificare |
| Libreria | Ricerca per titolo e contenuto (trascrizioni, sbobinature) | Da verificare |
| Libreria | Spostamento di contenuti tra materie | Da verificare |
| Quaderni | PencilKit, pagine multiple, modelli bianco/righe/quadretti/puntini, strumenti di sistema, undo/redo, zoom | Da verificare |
| Quaderni | Salvataggio vettoriale automatico e asincrono, una pagina in memoria | Da verificare (test `AppTests/PersistenceTests`) |
| Quaderni | Pagine: inserimento, duplicazione, spostamento, eliminazione | Da verificare (test scritti) |
| Quaderni | Testo digitato e immagini sotto l'inchiostro | Parziale: spostamento e ridimensionamento sì, rotazione no |
| Quaderni | Export PDF | Parziale: inchiostro rasterizzato ad alta risoluzione, non vettoriale |
| Registrazione | Avvio, pausa, ripresa, stop; AAC mono 48/64/96 kbps | Da verificare su iPad |
| Registrazione | Background e schermo bloccato (`UIBackgroundModes audio`) | Da verificare su iPad |
| Registrazione | Scrittura durante la registrazione, segnalibri delle pagine visitate e modificate | Da verificare |
| Registrazione | Segmenti chiusi ogni N minuti, manifest, recupero dopo crash | Da verificare (test con audio sintetico scritti) |
| Registrazione | Interruzioni, cambio microfono, reset dei servizi audio, spazio insufficiente | Da verificare su iPad |
| Registrazione | Profili (aula, segnale grezzo sperimentale, voce vicina), scelta microfono e capsula, prova di 10 s, avviso livello | Da verificare su iPad |
| Import | File, iCloud Drive, provider di documenti, "Apri con" | Da verificare. Share Extension non implementata: si usa "Apri con" |
| Riproduzione | Barra temporale, ±15 s, velocità, controlli in schermata di blocco | Da verificare |
| Trascrizione | OpenAI `gpt-transcribe` (glossario, lingue), `gpt-4o-transcribe-diarize`, `whisper-1` | Completa nel nucleo (test con trasporto simulato) |
| Trascrizione | File lunghi: chunk tagliati sulle pause, sovrapposizione, offset assoluti, deduplica, verifica della copertura, ripresa per chunk | **Completa** (test + end-to-end) |
| Trascrizione | Upload in background (URLSession background) | Da verificare su iPad |
| Trascrizione | Apple sul dispositivo (SpeechAnalyzer su iPadOS 26, SFSpeechRecognizer prima) | Da verificare; API di iPadOS 26 confrontate con la sessione WWDC25 |
| Trascrizione | Modelli offline a scelta (Parakeet Ultra/V3/Redux, Canary 1B v2, Whisper Large v3/Turbo/Small, SenseVoice): catalogo, consiglio in base all'iPad, download con avanzamento e annullamento, eliminazione, spazio occupato | Catalogo e raggruppamento dei tempi **testati**; download ed esecuzione da verificare su iPad |
| Trascrizione | Accuratezza dei modelli offline sull'italiano delle lezioni | **Non misurata**: l'ordine dei suggerimenti viene da benchmark pubblici |
| Sbobinatura | Pipeline A–F (preparazione, scaletta, sezioni in streaming, assemblaggio, verifica + correzione, normalizzazione editoriale) | **Completa** nel nucleo (test con provider simulati + end-to-end) |
| Sbobinatura | Tre modalità, prompt versionati e personalizzabili, glossario | Completa nel nucleo |
| Sbobinatura | Anti-omissioni e anti-allucinazioni: verifica del modello, controllo locale di numeri e nomi, rapporto di lunghezza, riferimenti ai segmenti | Completa nel nucleo (mai presentata come garanzia) |
| Editor | Lettura, modifica Markdown con formattazione, ricerca e sostituzione, immagini, versioni, rigenerazione della sezione, confronto audio/trascrizione/testo | Da verificare |
| Export | PDF impaginato, DOCX, Markdown, testo | DOCX **verificato**; PDF da verificare |
| PDF | Visualizzazione, annotazione con Pencil per pagina, export annotato, suggerimenti per il glossario | Da verificare |
| PDF | Uso delle slide come contesto della sbobinatura | **Non implementato** (fase successiva) |
| Backend | FastAPI, token, lavori idempotenti, upload in streaming, worker persistente, ripresa dopo riavvio, conservazione limitata | **Completa** (test) |
| Commerciale | Account utente, pagamenti, OAuth | Non implementati (vedi `docs/API_SETUP.md`) |
| Sincronizzazione | Collegamento dei singoli tratti all'audio | Non implementata: oggi c'è la granularità per pagina |
| Localizzazione | Interfaccia in italiano, catalogo stringhe pronto per altre lingue | Parziale: traduzioni non incluse |

## Avvio rapido

```bash
# Nucleo (qualsiasi sistema con Swift 5.10+)
cd Packages/QuadernoCore && swift test

# App: aprire in Xcode 16 o successivo
open QuadernoAI.xcodeproj

# Backend (facoltativo)
cd Backend && cp .env.example .env && ./run_dev.sh
```

Dettagli: [`docs/BUILD.md`](docs/BUILD.md) · Chiavi API e costi: [`docs/API_SETUP.md`](docs/API_SETUP.md) · Architettura: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · Test su iPad: [`docs/MANUAL_TEST_CHECKLIST.md`](docs/MANUAL_TEST_CHECKLIST.md) · Qualità: [`docs/QUALITY_EVALUATION.md`](docs/QUALITY_EVALUATION.md) · Ricerca: [`docs/RESEARCH.md`](docs/RESEARCH.md)

## Limiti dichiarati

- **Background:** la registrazione continua a schermo bloccato grazie alla modalità audio. Si ferma però se l'utente chiude forzatamente l'app o se il sistema la termina; in quel caso il recupero salva i segmenti già chiusi, quindi si perde al massimo l'ultimo segmento (3 minuti per default). L'elaborazione AI ad app sospesa è limitata da iPadOS: gli upload proseguono in background, il resto riprende dai checkpoint. Per un'elaborazione garantita ad app chiusa serve il backend.
- **Tempi della trascrizione:** `gpt-transcribe` non restituisce timestamp per frase. Senza diarizzazione o `whisper-1`, i collegamenti all'audio sono interpolati entro ciascun chunk (6 minuti per default, configurabile).
- **Qualità audio:** nessun modello può ricostruire parole che il microfono non ha acquisito. In aule grandi si consiglia un microfono esterno.
- **Verifica:** i controlli di completezza riducono il rischio di omissioni ed errori ma non lo eliminano.
