"""Test end-to-end: API FastAPI + worker Swift reale (QuadernoCore su Linux)
+ ffmpeg reale + provider finti via HTTP. Nessuna chiamata a servizi esterni.

Richiede il worker compilato:
  (cd Packages/QuadernoCore && swift build -c release --product quaderno-worker)
"""
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

from .conftest import auth, job_payload, make_settings
from .mock_providers import start_mock_server

ROOT = Path(__file__).resolve().parents[2]
WORKER = Path(os.environ.get("QUADERNO_TEST_WORKER_BIN", ROOT / "Packages/QuadernoCore/.build/release/quaderno-worker"))

pytestmark = pytest.mark.skipif(not WORKER.exists() or shutil.which("ffmpeg") is None, reason="worker Swift o ffmpeg non disponibili")


def make_audio(path: Path) -> None:
    # 50 s: tono, pausa, tono, pausa, tono (le pause guidano i tagli).
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=300:duration=18",
        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=2",
        "-f", "lavfi", "-i", "sine=frequency=400:duration=18",
        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=2",
        "-f", "lavfi", "-i", "sine=frequency=500:duration=10",
        "-filter_complex", "[0][1][2][3][4]concat=n=5:v=0:a=1", "-c:a", "aac", str(path),
    ], check=True)


def test_end_to_end_transcription_and_sbobinatura(tmp_path):
    server, state = start_mock_server()
    base = f"http://127.0.0.1:{server.server_address[1]}/v1"
    settings = make_settings(
        tmp_path, str(WORKER),
        QUADERNO_MAX_UPLOAD_MB="50",
        OPENAI_API_KEY="sk-test-openai", ANTHROPIC_API_KEY="sk-test-anthropic",
        OPENAI_BASE_URL=base, ANTHROPIC_BASE_URL=base, CHUNK_SECONDS="20",
    )
    audio = tmp_path / "lezione.m4a"
    make_audio(audio)
    try:
        with TestClient(create_app(settings)) as client:
            payload = job_payload(key="e2e")
            payload["includeGeneration"] = True
            job_id = client.post("/v1/jobs", json=payload, headers=auth()).json()["id"]
            client.put(f"/v1/jobs/{job_id}/audio", content=audio.read_bytes(), headers={**auth(), "X-File-Name": "lezione.m4a"})
            client.post(f"/v1/jobs/{job_id}/start", headers=auth())
            deadline = time.time() + 120
            status = {}
            while time.time() < deadline:
                status = client.get(f"/v1/jobs/{job_id}", headers=auth()).json()
                if status["status"] in {"completed", "failed"}:
                    break
                time.sleep(0.5)
            assert status["status"] == "completed", status
            result = client.get(f"/v1/jobs/{job_id}/result", headers=auth()).json()
    finally:
        server.shutdown()

    # Trascrizione: 3 parti, sovrapposizioni rimosse, copertura completa.
    assert sorted(call["index"] for call in state.transcription_calls) == [0, 1, 2]
    assert all(call["model"] == "gpt-transcribe" and call["keywords"] == 1 for call in state.transcription_calls)
    transcript = result["transcript"]
    full_text = " ".join(segment["text"] for segment in transcript["segments"])
    assert full_text.count("Weimar nel 1919 da Walter Gropius") == 1, full_text
    assert full_text.count("si trasferisce a Dessau") == 1, full_text
    assert transcript["report"]["coverageGaps"] == []
    assert transcript["report"]["unresolvedOverlapChunks"] == []
    assert transcript["segments"][-1]["end"] == pytest.approx(50, abs=0.5)

    # Sbobinatura: scaletta, due sezioni scritte in streaming e verificate.
    document = result["document"]
    assert document["title"] == "Il Bauhaus e il Werkbund"
    assert [section["title"] for section in document["sections"]] == ["Il Bauhaus", "Il Deutscher Werkbund"]
    assert all(section["state"] == "generated" for section in document["sections"])
    assert "1919" in document["sections"][0]["markdown"]
    assert document["promptVersion"].startswith("sbobinatura-it-")
    streamed = [call for call in state.message_calls if call.get("stream")]
    assert len(streamed) == 2
    assert all(call["model"] == "claude-opus-5-5" and call.get("fallbacks") == "default" for call in state.message_calls)
