# Architettura

## Livelli

```
┌───────────────────────────── App (iPadOS) ──────────────────────────────┐
│ Features/   SwiftUI + UIKit (PencilKit, PDFKit, UITextView)             │
│     │                                                                   │
│ Servizi     RecordingService · PlaybackService · JobRunner ·            │
│             ContentManager · ImportService · RecordingMaintenance        │
│     │                                                                   │
│ Storage     SwiftData (metadati) · FileStore (audio, disegni, PDF) ·     │
│             DrawingStore · KeychainStore · AppSettings                   │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │ import QuadernoCore
┌──────────────────────── QuadernoCore (Swift, multipiattaforma) ─────────┐
│ Transcription: ChunkPlanner · TranscriptionPipeline · TranscriptMerger · │
│                OverlapDeduplicator · OpenAITranscriptionProvider         │
│ Generation:    SbobinaturaEngine · PromptLibrary (prompt versionati) ·   │
│                AnthropicProvider · OpenAIResponsesProvider · verifica    │
│ Markdown/Export: parser · DocxExporter · ZipWriter                       │
│ Backend:       BackendJobClient · Networking: HTTPTransport, errori      │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │ stessa logica
┌──────────── Backend (FastAPI + quaderno-worker) ────────────┐
│ API con token · SQLite · upload in streaming · worker Swift  │
└──────────────────────────────────────────────────────────────┘
```

Il nucleo non dipende da UIKit né da AVFoundation: estrazione audio, trasporto HTTP e archiviazione dei checkpoint sono protocolli implementati dall'app (AVFoundation, URLSession in background) e dal worker (ffmpeg). Per questo la parte più delicata, cioè suddivisione, merge, prompt e verifica, è testata su Linux con provider simulati, senza costi.

## Modello dati (SwiftData, `QuadernoSchemaV1`)

`Subject` (con `SubjectGlossary`) → `Notebook` → `NotebookPage` → `DrawingData` (metadati; tratti in file) e `PageElement`.
`AudioRecording` → `AudioSegment`, `PageMark`, `Transcript` → `TranscriptSegment`.
`GeneratedDocument` → `GeneratedSection`, `DocumentVersion`.
Inoltre `PDFMaterial`, `ProcessingJob` (con identificatori, senza relazioni) e `AIProviderConfiguration`.

- **Perché SwiftData:** nativo, osservazione automatica in SwiftUI, schemi versionati con piano di migrazione (`QuadernoMigrationPlan`). Le relazioni sono semplici, ad albero con cascade, per ridurre il rischio di bug delle prime versioni di iOS 17.
- I dati voluminosi non stanno nel database: audio, disegni (`PKDrawing.dataRepresentation()`), PDF e immagini sono file separati, scritti in modo atomico.
- Eliminazioni sempre tramite `ContentManager`, che cancella anche i file. Eliminare una registrazione non elimina le sbobinature, salvo scelta esplicita.
- Se il database risulta illeggibile viene spostato da parte, non cancellato, e le registrazioni vengono ricostruite dai manifest su disco.

## Registrazione

```
microfono → AVAudioEngine.inputNode ──tap 4096 frame──▶ downmix mono + guadagno (vDSP)
            │                                         ├──▶ SignalAnalyzer (RMS/picco, lock)
            │                                         └──▶ coda seriale → SegmentedAudioWriter
            │                                                     │ AAC/M4A, file chiuso ogni N min
            ▼                                                     ▼
   AVAudioSession(.playAndRecord, modalità del profilo)   segment-0000.m4a, segment-0001.m4a …
                                                                  │
                                    manifest.json (atomico) ◀─────┘ a ogni chiusura, pausa, segnalibro
```

- **Indipendenza dalle viste:** `RecordingService` vive in `AppServices` per tutta la durata dell'app. Editor, libreria e schermate possono chiudersi senza effetti sulla registrazione.
- **Senza buchi:** la rotazione dei segmenti avviene fra due buffer dello stesso flusso continuo, e i test lo verificano contando i campioni.
- **Senza perdite gravi:** ogni segmento chiuso è un M4A valido. Un crash perde al massimo il segmento aperto. All'avvio `RecordingMaintenance` legge i manifest, scarta un ultimo segmento non finalizzato, ricrea il record se manca e unisce i segmenti in `audio.m4a`: prima in passthrough, poi con ricodifica se i formati differiscono, sempre verificando la durata.
- **Durata:** calcolata dai campioni acquisiti, non da timer. L'interfaccia la legge con `TimelineView`, che si ferma quando la vista non è visibile.
- **Eventi:** interruzioni (chiusura del segmento, pausa, ripresa automatica se il sistema lo consente), cambio di configurazione hardware (nuovo segmento con il nuovo formato), reset dei servizi media (motore ricreato), spazio in esaurimento (stop protetto).
- **Protezione dei file:** `completeUntilFirstUserAuthentication`. Con `complete` la scrittura fallirebbe a schermo bloccato: è il compromesso documentato in `FileStore`.
- **Batteria:** buffer di I/O da circa 93 ms, nessuna analisi AI né upload durante la registrazione, scritture del manifest rade (eventi e segnalibri raggruppati ogni 5 s), nessuna forma d'onda in tempo reale.

### Profili

| Profilo | Sessione | Elaborazione | Quando |
|---|---|---|---|
| Aula (predefinito) | `.default` | AGC di sistema, nessuna soppressione aggressiva | Docente lontano, microfono integrato |
| Aula — segnale grezzo (sperimentale) | `.measurement` | Nessuna elaborazione di sistema + guadagno digitale con limitatore | Microfono esterno di qualità; verificare con la prova di 10 s |
| Voce vicina | `.default` + voice processing | Cancellazione eco, riduzione rumore | Colloqui; sconsigliato in aula |

## Trascrizione di file lunghi

1. **Piano:** `ChunkPlanner` divide la durata in chunk da circa 6 minuti, entro un massimo ricavato dal limite in byte del provider (25 MB × 0,85 / bitrate). I confini cercano una pausa entro ±25 s: l'app analizza solo quelle finestre.
2. **Sovrapposizione:** ogni chunk dopo il primo include 4 s prima del confine. Le porzioni *core* formano una partizione esatta di `[0, durata]`, così la copertura è verificabile.
3. **Invio:** al massimo 2 in parallelo, retry con backoff, upload in background. Ogni risultato viene salvato subito in `chunk-NNNN.json`, così una ripresa invia solo i chunk mancanti.
4. **Merge:** offset assoluti. Con timestamp vale l'appartenenza per punto medio; senza timestamp il testo duplicato si trova allineando le parole normalizzate (tollera bordi troncati e piccole differenze). I casi non risolti finiscono nella diagnostica. Le allucinazioni note su audio silenzioso («Sottotitoli creati dalla comunità Amara.org»…) vengono rimosse e riportate.
5. **Verifica della copertura:** se resta un buco, il lavoro non viene dichiarato completato.

## Motore di sbobinatura (`SbobinaturaEngine`)

| Passaggio | Implementazione |
|---|---|
| A. Preparazione | Segmenti numerati `[S12 \| 00:12:30 \| interlocutore] testo` |
| B. Analisi tematica | Una chiamata JSON per finestra fino a 400k caratteri (in pratica una per lezione): sezioni contigue con elementi chiave (definizioni, esempi, nomi, date, numeri, correzioni). `OutlineNormalizer` ripara buchi e sovrapposizioni. Se fallisce, si usano sezioni per durata, segnalate |
| C. Rielaborazione | Una chiamata per sezione in streaming, con scaletta globale, elementi chiave, ultimo paragrafo precedente e glossario. Sezioni oltre 24k caratteri vengono divise in parti; un output troncato viene ridiviso a metà, fino a 3 livelli |
| D. Assemblaggio | Locale: intestazione con avviso sui limiti dei controlli più le sezioni |
| E. Completezza | Verifica JSON del modello (omissioni, valori, date, nomi, affermazioni non giustificate, correzioni del docente) più controlli locali (numeri, nomi propri e termini del glossario non ritrovati, rapporto di lunghezza, riferimenti fuori sezione). Correzione automatica dei problemi gravi, scartata se accorcia il testo oltre il 15% |
| F. Editoriale | Locale e deterministico: preamboli rimossi, gerarchia dei titoli, spaziature. Una passata editoriale con il modello su tutto il documento è stata valutata e scartata: raddoppierebbe il costo e rischierebbe di comprimere il testo, contro il requisito di completezza. La qualità stilistica è affidata al passaggio C |

- **Tracciabilità:** ogni paragrafo termina con `[[S12-S15]]`. L'app lo mostra come collegamento che porta al punto dell'audio e lo rimuove in esportazione. I passaggi dubbi sono `[[incerto: …]]`, evidenziati.
- **Ripresa:** scaletta e sezioni completate vengono salvate in un checkpoint, così un'interruzione non ripaga il lavoro già svolto.
- **Lavoro dello studente:** una nuova generazione crea un nuovo documento. La rigenerazione di una sezione salva prima una versione e non tocca le altre sezioni. Le versioni si possono ripristinare.
- **Prompt:** file versionati in `Packages/QuadernoCore/Sources/QuadernoCore/Resources/prompts/` (versione `sbobinatura-it-2026.10.1`), condivisi con il backend. Il prompt di sistema è personalizzabile e la versione effettiva viene registrata nel documento.

## Lavori persistenti (`JobRunner`)

Stati: `pending → preparing → uploading/transcribing → generating → verifying → completed`, più `waiting` (rete assente o tempo in background esaurito), `failed` e `cancelled`. Le transizioni non valide vengono rifiutate: un lavoro annullato non diventa mai completato.

- Un lavoro alla volta; niente duplicati per la stessa registrazione.
- Senza rete il lavoro passa in `waiting` e riprende alla riconnessione (`NWPathMonitor`).
- Errori transitori: nuovo tentativo con backoff da 30 s a 30 min, fino a 6 tentativi. Credenziali errate o credito esaurito portano subito a `failed`, con messaggio chiaro.
- In background: tempo extra concesso da iPadOS, upload dei chunk con `URLSession` in background (le risposte arrivate ad app terminata vengono salvate nel checkpoint dal delegate) e `BGProcessingTask` per riprendere i lavori in attesa.
- Il consenso è obbligatorio: senza `consentGivenAt` nessuna chiamata cloud.

## Backend

FastAPI (scelto per semplicità, tipizzazione e upload in streaming) più un worker Swift che riusa QuadernoCore, quindi un'unica logica di pipeline e prompt. Lavori idempotenti (`Idempotency-Key`), stato in SQLite, file per lavoro, worker come sottoprocesso con stato in `status.json`. Al riavvio del server i lavori interrotti riprendono dai checkpoint. L'audio viene eliminato a lavoro completato e il resto dopo 24 ore (configurabile). Dettagli in [`../Backend/README.md`](../Backend/README.md).
