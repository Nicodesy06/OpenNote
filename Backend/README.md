# Backend gestito di Quaderno AI

API FastAPI più worker Swift (`quaderno-worker`, basato su QuadernoCore): la trascrizione e la sbobinatura girano lato server, con lavori persistenti. L'elaborazione continua anche se l'iPad viene bloccato o l'app chiusa, e il risultato si recupera alla riapertura. I segreti dei provider AI restano sul server.

## Avvio locale

Requisiti: Python 3.11+, Swift 5.10+, ffmpeg.

```bash
cd Backend
cp .env.example .env            # imposta QUADERNO_API_TOKENS e le chiavi dei provider
./run_dev.sh                    # compila il worker e avvia l'API su http://0.0.0.0:8000
```

Per usarlo dall'iPad nella stessa rete: Impostazioni → Trascrizione → *Backend Quaderno AI*, indirizzo `http://<ip-del-mac>:8000` e il token scelto. In produzione esponilo **solo dietro HTTPS**, ad esempio con un reverse proxy (Caddy o nginx). Per accettare HTTP in sviluppo su iPad servirebbe un'eccezione ATS, non inclusa di proposito.

## Docker

```bash
docker build -f Backend/Dockerfile -t quaderno-backend .
docker run -p 8000:8000 --env-file Backend/.env -v quaderno-data:/data quaderno-backend
```

(Il Dockerfile non è stato provato nell'ambiente di sviluppo.)

## API

Tutte le richieste richiedono `Authorization: Bearer <token>`.

| Metodo | Percorso | Descrizione |
|---|---|---|
| GET | `/v1/health` | Verifica token e disponibilità |
| POST | `/v1/jobs` | Crea un lavoro (`BackendJobRequest`); idempotente per `Idempotency-Key` |
| PUT | `/v1/jobs/{id}/audio` | Carica l'audio come corpo binario in streaming (`X-File-Name`) |
| POST | `/v1/jobs/{id}/start` | Mette in coda (o riavvia un lavoro fallito) |
| GET | `/v1/jobs/{id}` | Stato: `created`, `uploaded`, `queued`, `running`, `completed`, `failed`, `cancelled` |
| GET | `/v1/jobs/{id}/result` | Trascrizione e sbobinatura (`BackendJobResult`) |
| DELETE | `/v1/jobs/{id}` | Annulla ed elimina subito tutti i dati |

## Sicurezza e conservazione

- Token confrontati in tempo costante; ogni token vede solo i propri lavori.
- Limite di dimensione per l'upload (`QUADERNO_MAX_UPLOAD_MB`), identificatori UUID generati dal server.
- L'audio viene eliminato appena il lavoro è completato (`QUADERNO_DELETE_AUDIO_AFTER_COMPLETION=1`); risultati e lavori dopo `QUADERNO_RETENTION_HOURS`. L'app elimina il lavoro dal server subito dopo averne scaricato il risultato.
- I log contengono solo identificativi e stati, mai audio o testi.
- Al worker vengono passate solo le variabili necessarie.
- Da aggiungere per un servizio pubblico: account utente veri (OAuth/OIDC), rate limiting, quote per utente, cifratura a riposo del volume dati, monitoraggio.

## Test

```bash
.venv/bin/pip install -r requirements-dev.txt
(cd ../Packages/QuadernoCore && swift build -c release --product quaderno-worker)
.venv/bin/python -m pytest
```

`tests/test_integration_worker.py` esegue un lavoro completo con il worker Swift reale, audio generato da ffmpeg e un server che simula OpenAI e Anthropic: nessuna chiamata esterna, nessun costo.
