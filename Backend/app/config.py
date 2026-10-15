"""Configurazione del backend da variabili d'ambiente."""
from __future__ import annotations

import hashlib
import hmac
import os
from dataclasses import dataclass, field
from pathlib import Path


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    worker_bin: str
    token_hashes: frozenset[str]
    max_upload_bytes: int
    retention_hours: float
    max_concurrent_jobs: int
    max_attempts: int
    delete_audio_after_completion: bool
    worker_env: dict[str, str] = field(default_factory=dict)

    @staticmethod
    def from_env(env: dict[str, str] | None = None) -> "Settings":
        env = dict(os.environ if env is None else env)
        tokens = [t.strip() for t in env.get("QUADERNO_API_TOKENS", "").split(",") if t.strip()]
        if not tokens:
            raise RuntimeError("QUADERNO_API_TOKENS non configurato: definisci almeno un token di accesso.")
        # Solo le variabili necessarie al worker vengono inoltrate al processo.
        forwarded = {
            key: env[key]
            for key in (
                "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_BASE_URL",
                "PROMPTS_DIR", "CHUNK_SECONDS", "FFMPEG_PATH", "FFPROBE_PATH", "PATH", "HOME",
            )
            if key in env
        }
        return Settings(
            data_dir=Path(env.get("QUADERNO_DATA_DIR", "./data")).resolve(),
            worker_bin=env.get("QUADERNO_WORKER_BIN", "quaderno-worker"),
            token_hashes=frozenset(_hash_token(t) for t in tokens),
            max_upload_bytes=int(float(env.get("QUADERNO_MAX_UPLOAD_MB", "600")) * 1024 * 1024),
            retention_hours=float(env.get("QUADERNO_RETENTION_HOURS", "24")),
            max_concurrent_jobs=max(1, int(env.get("QUADERNO_MAX_CONCURRENT_JOBS", "1"))),
            max_attempts=max(1, int(env.get("QUADERNO_MAX_ATTEMPTS", "3"))),
            delete_audio_after_completion=env.get("QUADERNO_DELETE_AUDIO_AFTER_COMPLETION", "1") != "0",
            worker_env=forwarded,
        )

    def owner_for(self, token: str) -> str | None:
        digest = _hash_token(token)
        match = False
        for known in self.token_hashes:
            # Confronto a tempo costante su tutti i token configurati.
            match |= hmac.compare_digest(digest, known)
        return digest[:16] if match else None
