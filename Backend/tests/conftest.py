import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402

TOKEN = "token-di-prova"


def make_settings(tmp_path: Path, worker: str, **overrides) -> Settings:
    env = {
        "QUADERNO_API_TOKENS": f"{TOKEN},altro-token",
        "QUADERNO_DATA_DIR": str(tmp_path / "data"),
        "QUADERNO_WORKER_BIN": worker,
        "QUADERNO_MAX_UPLOAD_MB": "1",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }
    env.update(overrides)
    return Settings.from_env(env)


@pytest.fixture
def client(tmp_path):
    worker = str(Path(__file__).with_name("fake_worker.py"))
    app = create_app(make_settings(tmp_path, worker))
    with TestClient(app) as test_client:
        yield test_client


def auth(token: str = TOKEN) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def job_payload(subject: str = "Storia del Design", key: str = "chiave-1") -> dict:
    return {
        "idempotencyKey": key,
        "mode": "integrale",
        "subjectName": subject,
        "lessonTitle": "Lezione 1",
        "documentLanguage": "italiano",
        "transcriptionLanguages": ["it"],
        "glossary": ["Bauhaus"],
        "instructions": None,
        "transcriptionModel": "gpt-transcribe",
        "generationProvider": "anthropic",
        "generationModel": "claude-opus-5-5",
        "includeGeneration": False,
    }
