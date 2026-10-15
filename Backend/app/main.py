"""Backend gestito di Quaderno AI (FastAPI).

Responsabilità:
- autenticazione con token (i segreti dei provider AI restano sul server);
- lavori identificabili e idempotenti (chiave Idempotency-Key);
- upload in streaming di file audio grandi (nessun caricamento in RAM);
- esecuzione persistente nel worker Swift, con ripresa dopo riavvio;
- recupero dei risultati anche se l'iPad era bloccato durante l'elaborazione;
- conservazione limitata: audio eliminato a lavoro completato, tutto il
  resto dopo QUADERNO_RETENTION_HOURS.

Nessun log contiene audio, trascrizioni o testi generati.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import re
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.responses import FileResponse

from .config import Settings
from .store import JobStore, TERMINAL
from .worker import WorkerManager

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("quaderno.api")

REQUIRED_FIELDS = {"idempotencyKey": str, "mode": str, "subjectName": str, "lessonTitle": str, "documentLanguage": str, "transcriptionLanguages": list, "glossary": list, "transcriptionModel": str, "generationProvider": str, "generationModel": str, "includeGeneration": bool}
ALLOWED_MODES = {"integrale", "trascrizionePulita", "riassunto"}


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    store = JobStore(settings.data_dir)
    manager = WorkerManager(store, settings)

    async def cleanup_loop() -> None:
        while True:
            try:
                for job in store.expired(settings.retention_hours * 3600):
                    if job.status not in {"running", "queued"}:
                        store.delete(job.id)
                        log.info("Lavoro %s eliminato per scadenza", job.id)
            except Exception:  # noqa: BLE001
                log.exception("Pulizia non riuscita")
            await asyncio.sleep(600)

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI):
        await manager.start()
        cleaner = asyncio.create_task(cleanup_loop())
        yield
        cleaner.cancel()
        await manager.stop()

    app = FastAPI(title="Quaderno AI backend", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.manager = manager
    app.state.settings = settings

    def owner(authorization: str = Header(default="")) -> str:
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Token mancante")
        found = settings.owner_for(token.strip())
        if found is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Token non valido")
        return found

    def load_job(job_id: str, owner_id: str):
        try:
            job = store.get(job_id, owner=owner_id)
        except ValueError:
            job = None
        if job is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Lavoro non trovato")
        return job

    @app.get("/v1/health")
    async def health(owner_id: str = Depends(owner)) -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/jobs")
    async def create_job(payload: dict[str, Any], owner_id: str = Depends(owner), idempotency_key: str | None = Header(default=None, alias="Idempotency-Key")) -> dict[str, Any]:
        for field, kind in REQUIRED_FIELDS.items():
            if not isinstance(payload.get(field), kind):
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=f"Campo mancante o non valido: {field}")
        if payload["mode"] not in ALLOWED_MODES:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Modalità non valida")
        key = (idempotency_key or payload["idempotencyKey"])[:200]
        job, created = store.create(owner_id, key, payload)
        if created:
            log.info("Lavoro %s creato", job.id)
        return job.public()

    @app.put("/v1/jobs/{job_id}/audio")
    async def upload_audio(job_id: str, request: Request, owner_id: str = Depends(owner), x_file_name: str = Header(default="audio.m4a")) -> dict[str, Any]:
        job = load_job(job_id, owner_id)
        if job.status not in {"created", "uploaded"}:
            raise HTTPException(status.HTTP_409_CONFLICT, detail="L'audio di questo lavoro è già in elaborazione")
        extension = (x_file_name.rsplit(".", 1)[-1] if "." in x_file_name else "m4a").lower()
        if not re.fullmatch(r"[a-z0-9]{1,5}", extension):
            extension = "m4a"
        name = f"audio.{extension}"
        directory = store.job_dir(job_id)
        partial = directory / (name + ".part")
        size = 0
        with partial.open("wb") as handle:
            async for chunk in request.stream():
                size += len(chunk)
                if size > settings.max_upload_bytes:
                    handle.close()
                    partial.unlink(missing_ok=True)
                    raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="File troppo grande")
                handle.write(chunk)
        if size == 0:
            partial.unlink(missing_ok=True)
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="File vuoto")
        partial.replace(directory / name)
        store.update(job_id, status="uploaded", audio_file=name, step="Audio ricevuto")
        return store.get(job_id).public()

    @app.post("/v1/jobs/{job_id}/start")
    async def start_job(job_id: str, owner_id: str = Depends(owner)) -> dict[str, Any]:
        job = load_job(job_id, owner_id)
        if job.status == "created":
            raise HTTPException(status.HTTP_409_CONFLICT, detail="Carica prima l'audio")
        if job.status in {"uploaded", "failed"}:
            store.update(job_id, status="queued", step="In coda", error=None)
            await manager.enqueue(job_id)
        return store.get(job_id).public()

    @app.get("/v1/jobs/{job_id}")
    async def job_status(job_id: str, owner_id: str = Depends(owner)) -> dict[str, Any]:
        return load_job(job_id, owner_id).public()

    @app.get("/v1/jobs/{job_id}/result")
    async def job_result(job_id: str, owner_id: str = Depends(owner)):
        job = load_job(job_id, owner_id)
        result = store.job_dir(job_id) / "result.json"
        if job.status != "completed" or not result.exists():
            raise HTTPException(status.HTTP_409_CONFLICT, detail="Risultato non ancora disponibile")
        return FileResponse(result, media_type="application/json")

    @app.delete("/v1/jobs/{job_id}")
    async def delete_job(job_id: str, owner_id: str = Depends(owner)) -> dict[str, str]:
        job = load_job(job_id, owner_id)
        if job.status not in TERMINAL:
            await manager.cancel(job_id)
        store.delete(job_id)
        return {"status": "deleted"}

    return app

