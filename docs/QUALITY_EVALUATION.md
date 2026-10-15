# Valutazione della qualità di trascrizioni e sbobinature

Le metriche si misurano **separatamente** con `tools/quality_eval/evaluate.py`, su un dataset di lezioni universitarie italiane con riferimenti scritti a mano.

## Preparare il dataset

Per ogni lezione crea una cartella con:

| File | Contenuto | Come ottenerlo |
|---|---|---|
| `reference_transcript.txt` | Trascrizione corretta parola per parola | Correzione manuale di 10–20 minuti di audio (consigliato: 3 annotatori su un campione) |
| `hypothesis_transcript.txt` | Trascrizione dell'app | Trascrizione → Esporta → Testo semplice |
| `sbobinatura.md` | Sbobinatura dell'app | Sbobinatura → Esporta → Markdown |
| `terms.txt` | Termini tecnici e nomi propri, uno per riga | Dal glossario della materia |
| `facts.json` | Fatti chiave (`keywords`) e affermazioni vietate (`forbidden`) | Scritti da chi conosce la materia |

Composizione consigliata: almeno 10 lezioni di discipline diverse (umanistiche, STEM con formule e sigle, lingue straniere) e condizioni diverse (aula grande, microfono esterno, domande degli studenti, docente che si corregge). Un esempio è in `tools/quality_eval/sample_dataset/`.

## Metriche

| # | Metrica | Calcolo | Obiettivo indicativo |
|---|---|---|---|
| 1 | Accuratezza STT | WER (Levenshtein sulle parole normalizzate) | < 10% in aula con buon segnale |
| 2 | Termini tecnici | Termini del glossario presenti nel riferimento ma assenti o storpiati | ≥ 95% corretti |
| 3 | Omissioni | Fatti chiave del riferimento assenti nella sbobinatura | 0 nella modalità integrale |
| 4 | Allucinazioni | Numeri e nomi propri non presenti nel riferimento; affermazioni vietate | 0 vietate; i candidati vanno rivisti a mano |
| 5 | Completezza | Rapporto di lunghezza sbobinatura/riferimento | 0,7–1,1 (integrale), 0,2–0,45 (riassunto) |
| 6 | Qualità editoriale | Titoli, paragrafi, quota di righe in elenco, lunghezza media delle frasi, intercalari residui | Prosa prevalente, intercalari ≈ 0 |

```bash
python3 tools/quality_eval/evaluate.py path/al/dataset --json report.json
```

Le metriche 4 e 6 sono euristiche: segnalano candidati, non danno verdetti. Per la qualità editoriale si affianca una valutazione umana su scala 1–5 (correttezza, scorrevolezza, struttura, fedeltà al docente).

## Uso

- Confronta modelli e impostazioni (effort, verifica attiva o no, durata dei chunk) **sullo stesso dataset**.
- Ricontrolla dopo ogni modifica ai prompt: la versione del prompt è registrata in ogni documento.
- Non dichiarare obiettivi raggiunti senza averli misurati.
