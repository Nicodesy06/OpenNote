import time

from .conftest import auth, job_payload


def wait_for(client, job_id, statuses, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = client.get(f"/v1/jobs/{job_id}", headers=auth()).json()
        if body["status"] in statuses:
            return body
        time.sleep(0.2)
    raise AssertionError(f"Stato atteso {statuses}, ultimo {body}")


def test_requires_valid_token(client):
    assert client.get("/v1/health").status_code == 401
    assert client.get("/v1/health", headers=auth("sbagliato")).status_code == 401
    assert client.get("/v1/health", headers=auth()).json() == {"status": "ok"}


def test_full_job_lifecycle(client):
    created = client.post("/v1/jobs", json=job_payload(), headers={**auth(), "Idempotency-Key": "k1"}).json()
    assert created["status"] == "created"
    job_id = created["id"]
    # Avvio prima dell'upload: rifiutato.
    assert client.post(f"/v1/jobs/{job_id}/start", headers=auth()).status_code == 409
    uploaded = client.put(f"/v1/jobs/{job_id}/audio", content=b"\x00" * 2048, headers={**auth(), "Content-Type": "audio/mp4", "X-File-Name": "lezione.m4a"}).json()
    assert uploaded["status"] == "uploaded"
    # Risultato non ancora disponibile.
    assert client.get(f"/v1/jobs/{job_id}/result", headers=auth()).status_code == 409
    client.post(f"/v1/jobs/{job_id}/start", headers=auth())
    done = wait_for(client, job_id, {"completed", "failed"})
    assert done["status"] == "completed", done
    result = client.get(f"/v1/jobs/{job_id}/result", headers=auth()).json()
    assert result["transcript"]["segments"][0]["text"] == "Buongiorno."
    # L'audio viene eliminato a lavoro completato.
    store = client.app.state.store
    assert not (store.job_dir(job_id) / "audio.m4a").exists()
    assert client.delete(f"/v1/jobs/{job_id}", headers=auth()).json() == {"status": "deleted"}
    assert client.get(f"/v1/jobs/{job_id}", headers=auth()).status_code == 404


def test_idempotent_creation(client):
    first = client.post("/v1/jobs", json=job_payload(key="stessa"), headers=auth()).json()
    second = client.post("/v1/jobs", json=job_payload(key="stessa"), headers=auth()).json()
    assert first["id"] == second["id"]
    other_owner = client.post("/v1/jobs", json=job_payload(key="stessa"), headers=auth("altro-token")).json()
    assert other_owner["id"] != first["id"]


def test_jobs_are_isolated_between_tokens(client):
    job_id = client.post("/v1/jobs", json=job_payload(), headers=auth()).json()["id"]
    assert client.get(f"/v1/jobs/{job_id}", headers=auth("altro-token")).status_code == 404
    assert client.delete(f"/v1/jobs/{job_id}", headers=auth("altro-token")).status_code == 404


def test_validation_and_upload_limits(client):
    bad = job_payload()
    del bad["subjectName"]
    assert client.post("/v1/jobs", json=bad, headers=auth()).status_code == 422
    wrong_mode = job_payload()
    wrong_mode["mode"] = "inventato"
    assert client.post("/v1/jobs", json=wrong_mode, headers=auth()).status_code == 422
    job_id = client.post("/v1/jobs", json=job_payload(key="limiti"), headers=auth()).json()["id"]
    too_big = client.put(f"/v1/jobs/{job_id}/audio", content=b"\x00" * (2 * 1024 * 1024), headers=auth())
    assert too_big.status_code == 413
    assert client.put(f"/v1/jobs/{job_id}/audio", content=b"", headers=auth()).status_code == 400
    assert client.get("/v1/jobs/non-un-uuid", headers=auth()).status_code == 404


def test_definitive_failure_is_reported(client):
    job_id = client.post("/v1/jobs", json=job_payload(subject="FAIL", key="f"), headers=auth()).json()["id"]
    client.put(f"/v1/jobs/{job_id}/audio", content=b"\x00" * 100, headers=auth())
    client.post(f"/v1/jobs/{job_id}/start", headers=auth())
    failed = wait_for(client, job_id, {"failed"})
    assert "non è valida" in failed["error"]
    # Un lavoro fallito può essere riavviato esplicitamente.
    restarted = client.post(f"/v1/jobs/{job_id}/start", headers=auth()).json()
    assert restarted["status"] in {"queued", "running", "failed"}


def test_retryable_failure_is_requeued(client):
    job_id = client.post("/v1/jobs", json=job_payload(subject="RETRY", key="r"), headers=auth()).json()["id"]
    client.put(f"/v1/jobs/{job_id}/audio", content=b"\x00" * 100, headers=auth())
    client.post(f"/v1/jobs/{job_id}/start", headers=auth())
    queued = wait_for(client, job_id, {"queued"}, timeout=10)
    assert "Nuovo tentativo" in queued["step"]
    assert "503" in queued["error"]
