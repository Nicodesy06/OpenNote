"""Server HTTP finto che imita le API OpenAI (trascrizione) e Anthropic
(Messages, anche in streaming SSE) per i test end-to-end senza costi."""
from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class MockState:
    def __init__(self):
        self.transcription_calls: list[dict] = []
        self.message_calls: list[dict] = []
        self.lock = threading.Lock()


def _chunk_index(body: bytes) -> int:
    match = re.search(rb'filename="chunk-(\d+)\.', body)
    return int(match.group(1)) if match else -1


def _field(body: bytes, name: str) -> str | None:
    match = re.search(rb'name="' + re.escape(name.encode()) + rb'"\r\n\r\n([^\r]*)\r\n', body)
    return match.group(1).decode() if match else None


TEXTS = [
    "Buongiorno a tutti, oggi parliamo del Bauhaus. Il Bauhaus viene fondato a Weimar nel 1919 da Walter Gropius.",
    "Weimar nel 1919 da Walter Gropius. L'idea è unire arte e artigianato. Nel 1925 la scuola si trasferisce a Dessau.",
    "si trasferisce a Dessau. Passiamo ora al Deutscher Werkbund, fondato nel 1907 a Monaco.",
]


def make_handler(state: MockState):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # silenzioso nei test
            pass

        def _json(self, payload, status=200):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            if self.path.endswith("/audio/transcriptions"):
                if self.headers.get("Authorization") != "Bearer sk-test-openai":
                    return self._json({"error": {"message": "Incorrect API key"}}, 401)
                index = _chunk_index(body)
                with state.lock:
                    state.transcription_calls.append({"index": index, "model": _field(body, "model"), "keywords": body.count(b'name="keywords[]"')})
                text = TEXTS[index] if 0 <= index < len(TEXTS) else "Fine della lezione, ci vediamo la prossima settimana."
                return self._json({"text": text, "languages": [{"code": "it"}]})
            if self.path.endswith("/messages"):
                if self.headers.get("x-api-key") != "sk-test-anthropic":
                    return self._json({"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}, 401)
                request = json.loads(body)
                with state.lock:
                    state.message_calls.append(request)
                prompt = request["messages"][0]["content"]
                ids = [int(m) for m in re.findall(r"\[S(\d+) \|", prompt)]
                schema = (request.get("output_config") or {}).get("format", {}).get("schema", {})
                if "lessonTitle" in json.dumps(schema):
                    last = max(ids) if ids else 0
                    middle = last // 2
                    outline = {"lessonTitle": "Il Bauhaus e il Werkbund", "sections": [
                        {"title": "Il Bauhaus", "firstSegment": 0, "lastSegment": middle, "summary": "", "keyItems": [{"kind": "data", "text": "1919"}]},
                        {"title": "Il Deutscher Werkbund", "firstSegment": middle + 1, "lastSegment": last, "summary": "", "keyItems": []},
                    ]}
                    return self._message(json.dumps(outline))
                if "issues" in json.dumps(schema):
                    return self._message(json.dumps({"issues": [], "unverifiable": []}))
                title = re.search(r"Sezione da scrivere: (.*)", prompt)
                lines = [line.split("] ", 1)[1] for line in prompt.split("Trascrizione della sezione:")[-1].splitlines() if line.startswith("[S")]
                text = f"## {title.group(1) if title else 'Sezione'}\n\n" + " ".join(lines) + f" [[S{min(ids) if ids else 0}-S{max(ids) if ids else 0}]]"
                if request.get("stream"):
                    return self._stream(text)
                return self._message(text)
            self._json({"error": {"message": "not found"}}, 404)

        def _message(self, text):
            self._json({"model": "claude-opus-5-5", "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": {"input_tokens": 100, "output_tokens": 50}})

        def _stream(self, text):
            events = [
                {"type": "message_start", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 120}}},
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            ]
            for start in range(0, len(text), 40):
                events.append({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text[start:start + 40]}})
            events += [{"type": "content_block_stop", "index": 0}, {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 60}}, {"type": "message_stop"}]
            payload = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return Handler


def start_mock_server() -> tuple[ThreadingHTTPServer, MockState]:
    state = MockState()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, state
