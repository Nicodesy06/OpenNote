#!/usr/bin/env python3
"""Worker finto per i test dell'API (nessuna chiamata ai provider).

Comportamento in base a subjectName: "FAIL" → errore definitivo,
"RETRY" → errore ritentabile, altrimenti risultato valido.
"""
import json
import sys
import time
from pathlib import Path

directory = Path(sys.argv[3])
job = json.loads((directory / "job.json").read_text())
request = job["request"]
assert (directory / job["audioFileName"]).exists(), "audio mancante"


def status(value, progress, step, error=None, retryable=False):
    tmp = directory / "status.json.tmp"
    tmp.write_text(json.dumps({"status": value, "progress": progress, "step": step, "error": error, "retryable": retryable, "updatedAt": "2026-10-15T00:00:00Z"}))
    tmp.replace(directory / "status.json")


status("running", 0.5, "Trascrizione: 1 di 2 parti")
time.sleep(0.3)
if request["subjectName"] == "FAIL":
    status("failed", 0, "Non riuscito", error="La chiave API di OpenAI non è valida o è stata revocata.")
    sys.exit(1)
if request["subjectName"] == "RETRY":
    status("failed", 0, "Non riuscito", error="Il servizio non è al momento disponibile (HTTP 503).", retryable=True)
    sys.exit(1)
result = {
    "transcript": {
        "segments": [{"index": 0, "start": 0, "end": 5, "text": "Buongiorno.", "chunkIndex": 0, "precision": "interpolated"}],
        "report": {"chunkCount": 1, "coverageGaps": [], "unresolvedOverlapChunks": [], "emptyChunks": [], "removedSuspectPhrases": [], "precision": "interpolated"},
        "detectedLanguages": ["it"],
    },
    "transcriptionProviderID": "openai",
    "transcriptionModel": "gpt-transcribe",
    "document": None,
}
(directory / "result.json").write_text(json.dumps(result))
status("completed", 1, "Completato")
