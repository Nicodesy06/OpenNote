#!/usr/bin/env bash
# Avvio locale per sviluppo: compila il worker e avvia l'API su :8000.
set -euo pipefail
cd "$(dirname "$0")"
( cd ../Packages/QuadernoCore && swift build -c release --product quaderno-worker )
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install --quiet -r requirements.txt
set -a; [ -f .env ] && . ./.env; set +a
exec .venv/bin/uvicorn --factory app.main:create_app --host 0.0.0.0 --port 8000
