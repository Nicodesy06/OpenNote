"""Esecuzione dei lavori nel worker Swift (QuadernoCore) come sottoprocesso.

Il worker salva checkpoint su disco: se il server si riavvia, i lavori in
corso vengono rimessi in coda e riprendono dai chunk e dalle sezioni già
completati, senza ripetere chiamate già pagate.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
from pathlib import Path

from .config import Settings
from .store import Job, JobStore

log = logging.getLogger("quaderno.worker")


class WorkerManager:
    def __init__(self, store: JobStore, settings: Settings):
        self.store = store
        self.settings = settings
        self.queue: asyncio.Queue[str] = asyncio.Queue()
        self.processes: dict[str, asyncio.subprocess.Process] = {}
        self.cancelled: set[str] = set()
        self._tasks: list[asyncio.Task] = []
        self._queued: set[str] = set()

    async def start(self) -> None:
        # Lavori interrotti da un riavvio del server: di nuovo in coda.
        for job in self.store.with_status({"queued", "running"}):
            self.store.update(job.id, status="queued", step="Ripresa dopo il riavvio del server")
            await self.enqueue(job.id)
        for _ in range(self.settings.max_concurrent_jobs):
            self._tasks.append(asyncio.create_task(self._consume()))

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        for process in list(self.processes.values()):
            if process.returncode is None:
                process.send_signal(signal.SIGTERM)

    async def enqueue(self, job_id: str) -> None:
        if job_id in self._queued:
            return
        self._queued.add(job_id)
        await self.queue.put(job_id)

    async def cancel(self, job_id: str) -> None:
        self.cancelled.add(job_id)
        process = self.processes.get(job_id)
        if process and process.returncode is None:
            process.kill()

    async def _consume(self) -> None:
        while True:
            job_id = await self.queue.get()
            self._queued.discard(job_id)
            try:
                await self._run(job_id)
            except Exception:  # noqa: BLE001 - il worker non deve fermare la coda
                log.exception("Errore inatteso nel lavoro %s", job_id)
                self.store.update(job_id, status="failed", error="Errore interno del server")
            finally:
                self.queue.task_done()

    def _read_status(self, directory: Path) -> dict | None:
        try:
            return json.loads((directory / "status.json").read_text())
        except (OSError, ValueError):
            return None

    async def _run(self, job_id: str) -> None:
        job = self.store.get(job_id)
        if job is None or job.status in {"completed", "cancelled"} or job_id in self.cancelled:
            return
        directory = self.store.job_dir(job_id)
        (directory / "job.json").write_text(json.dumps({"request": job.request, "audioFileName": job.audio_file}))
        attempts = job.attempts + 1
        self.store.update(job_id, status="running", attempts=attempts, error=None, step="Avvio dell'elaborazione")
        env = dict(self.settings.worker_env)
        process = await asyncio.create_subprocess_exec(
            self.settings.worker_bin, "run", "--job-dir", str(directory),
            env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        self.processes[job_id] = process
        stderr_task = asyncio.create_task(process.stderr.read()) if process.stderr else None
        try:
            while process.returncode is None:
                try:
                    await asyncio.wait_for(process.wait(), timeout=2)
                except asyncio.TimeoutError:
                    pass
                status = self._read_status(directory)
                if status and status.get("status") == "running":
                    self.store.update(job_id, progress=float(status.get("progress", 0)), step=str(status.get("step", ""))[:200])
        finally:
            self.processes.pop(job_id, None)
        stderr = (await stderr_task).decode("utf-8", "replace")[-500:] if stderr_task else ""

        if job_id in self.cancelled:
            self.store.update(job_id, status="cancelled", step="Annullato")
            return
        status = self._read_status(directory) or {}
        if process.returncode == 0 and status.get("status") == "completed" and (directory / "result.json").exists():
            self.store.update(job_id, status="completed", progress=1.0, step="Completato", error=None)
            if self.settings.delete_audio_after_completion:
                self.store.remove_audio(self.store.get(job_id))
            log.info("Lavoro %s completato", job_id)
            return
        message = status.get("error") or (f"Il worker è terminato con codice {process.returncode}" + (f": {stderr.strip().splitlines()[-1]}" if stderr.strip() else ""))
        retryable = bool(status.get("retryable"))
        if retryable and attempts < self.settings.max_attempts:
            delay = min(600, 30 * 2 ** (attempts - 1))
            self.store.update(job_id, status="queued", step=f"Nuovo tentativo tra {delay} s", error=message)
            asyncio.get_running_loop().call_later(delay, lambda: asyncio.ensure_future(self.enqueue(job_id)))
        else:
            self.store.update(job_id, status="failed", step="Non riuscito", error=message)
        log.warning("Lavoro %s non riuscito (ritentabile=%s)", job_id, retryable)
