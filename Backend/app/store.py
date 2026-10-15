"""Archivio persistente dei lavori (SQLite) e file su disco."""
from __future__ import annotations

import json
import shutil
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

TERMINAL = {"completed", "failed", "cancelled"}


@dataclass
class Job:
    id: str
    owner: str
    idempotency_key: str
    status: str
    progress: float
    step: str
    error: str | None
    attempts: int
    created_at: float
    updated_at: float
    request: dict[str, Any]
    audio_file: str | None

    def public(self) -> dict[str, Any]:
        return {"id": self.id, "status": self.status, "progress": round(self.progress, 4), "step": self.step, "error": self.error}


class JobStore:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.jobs_dir = data_dir / "jobs"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(str(data_dir / "jobs.sqlite3"), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                owner TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                status TEXT NOT NULL,
                progress REAL NOT NULL DEFAULT 0,
                step TEXT NOT NULL DEFAULT '',
                error TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                request TEXT NOT NULL,
                audio_file TEXT,
                UNIQUE(owner, idempotency_key)
            )"""
        )
        self._db.commit()

    def job_dir(self, job_id: str) -> Path:
        # Gli identificativi sono UUID generati dal server: nessun rischio di
        # path traversal, ma si verifica comunque il formato.
        uuid.UUID(job_id)
        return self.jobs_dir / job_id

    def _row(self, row: tuple | None) -> Job | None:
        if row is None:
            return None
        return Job(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], json.loads(row[10]), row[11])

    _COLUMNS = "id, owner, idempotency_key, status, progress, step, error, attempts, created_at, updated_at, request, audio_file"

    def create(self, owner: str, idempotency_key: str, request: dict[str, Any]) -> tuple[Job, bool]:
        """Crea un lavoro; se la chiave di idempotenza esiste già restituisce
        quello esistente (secondo valore False)."""
        with self._lock:
            existing = self._db.execute(f"SELECT {self._COLUMNS} FROM jobs WHERE owner=? AND idempotency_key=?", (owner, idempotency_key)).fetchone()
            if existing:
                return self._row(existing), False
            now = time.time()
            job_id = str(uuid.uuid4())
            self._db.execute(
                f"INSERT INTO jobs ({self._COLUMNS}) VALUES (?, ?, ?, 'created', 0, '', NULL, 0, ?, ?, ?, NULL)",
                (job_id, owner, idempotency_key, now, now, json.dumps(request)),
            )
            self._db.commit()
            self.job_dir(job_id).mkdir(parents=True, exist_ok=True)
            return self.get(job_id), True

    def get(self, job_id: str, owner: str | None = None) -> Job | None:
        with self._lock:
            row = self._db.execute(f"SELECT {self._COLUMNS} FROM jobs WHERE id=?", (job_id,)).fetchone()
        job = self._row(row)
        if job and owner is not None and job.owner != owner:
            return None
        return job

    def update(self, job_id: str, **fields: Any) -> None:
        if not fields:
            return
        fields["updated_at"] = time.time()
        assignments = ", ".join(f"{key}=?" for key in fields)
        with self._lock:
            self._db.execute(f"UPDATE jobs SET {assignments} WHERE id=?", (*fields.values(), job_id))
            self._db.commit()

    def with_status(self, statuses: set[str]) -> list[Job]:
        placeholders = ",".join("?" for _ in statuses)
        with self._lock:
            rows = self._db.execute(f"SELECT {self._COLUMNS} FROM jobs WHERE status IN ({placeholders}) ORDER BY created_at", tuple(statuses)).fetchall()
        return [self._row(r) for r in rows]

    def delete(self, job_id: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM jobs WHERE id=?", (job_id,))
            self._db.commit()
        shutil.rmtree(self.job_dir(job_id), ignore_errors=True)

    def expired(self, older_than_seconds: float) -> list[Job]:
        limit = time.time() - older_than_seconds
        with self._lock:
            rows = self._db.execute(f"SELECT {self._COLUMNS} FROM jobs WHERE updated_at < ?", (limit,)).fetchall()
        return [self._row(r) for r in rows]

    def remove_audio(self, job: Job) -> None:
        directory = self.job_dir(job.id)
        if job.audio_file:
            (directory / job.audio_file).unlink(missing_ok=True)
        shutil.rmtree(directory / "chunks", ignore_errors=True)
