#!/usr/bin/env python3
"""
rocky_tts_server.py — Kokoro TTS + RAG server for agentrocky
Listens on http://127.0.0.1:59720

Endpoints:
  GET  /health          — liveness check
  POST /                — TTS: {"text": "..."} → WAV bytes
  POST /ask             — RAG: {"query": "..."} → {"answer": "...", "chunks": [...]}

RAG uses local sentence-transformers embeddings (no API key) over rocky_knowledge.txt.
TTS uses Kokoro am_puck voice at speed 0.9.
"""

import sys
import os
import json
import logging
import argparse
import struct
import re
import numpy as np
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format="[rocky-tts] %(message)s")
log = logging.getLogger(__name__)

VOICE = "am_puck"
SPEED = 0.9
SAMPLE_RATE = 24000  # Kokoro native output rate
KNOWLEDGE_FILE = os.path.join(os.path.dirname(__file__), "rocky_knowledge.txt")
TOP_K = 5  # number of chunks to retrieve per query

# ── globals loaded once at startup ──────────────────────────────────────────
pipeline = None       # Kokoro TTS pipeline
embedder = None       # SentenceTransformer model
chunks: list[str] = []        # knowledge base sentences
chunk_embeddings = None       # np.ndarray shape (N, D)


# ── Knowledge base loading & embedding ──────────────────────────────────────

def load_knowledge():
    global embedder, chunks, chunk_embeddings
    if not os.path.exists(KNOWLEDGE_FILE):
        log.warning("Knowledge file not found: %s — RAG disabled", KNOWLEDGE_FILE)
        return

    log.info("Loading Rocky knowledge base...")
    with open(KNOWLEDGE_FILE) as f:
        raw = f.read()

    # Split into individual facts — one per non-empty, non-header line
    all_lines = [l.strip() for l in raw.splitlines()]
    chunks = [
        l for l in all_lines
        if l and not l.startswith("#") and not l.startswith("##")
    ]
    log.info("Loaded %d knowledge chunks", len(chunks))

    log.info("Loading sentence-transformers embedder (first run downloads ~90 MB)...")
    from sentence_transformers import SentenceTransformer
    embedder = SentenceTransformer("all-MiniLM-L6-v2")
    chunk_embeddings = embedder.encode(chunks, convert_to_numpy=True, show_progress_bar=False)
    log.info("RAG ready. %d chunks embedded.", len(chunks))


def retrieve(query: str, k: int = TOP_K) -> list[str]:
    """Return the top-k most relevant knowledge chunks for the query."""
    if embedder is None or chunk_embeddings is None:
        return []
    q_emb = embedder.encode([query], convert_to_numpy=True)
    # Cosine similarity
    norms = np.linalg.norm(chunk_embeddings, axis=1, keepdims=True) * np.linalg.norm(q_emb, axis=1)
    norms = np.where(norms == 0, 1e-9, norms)
    scores = (chunk_embeddings @ q_emb.T).flatten() / norms.flatten()
    top_idx = np.argsort(scores)[::-1][:k]
    return [chunks[i] for i in top_idx]


def build_rocky_answer(query: str, retrieved: list[str]) -> str:
    """
    Turn retrieved facts into a Rocky-voiced answer.
    Rocky speaks in short declarative fragments, no articles, verdict-first.
    """
    if not retrieved:
        return "No understand. Ask again, question?"

    # Deduplicate while preserving order
    seen = set()
    facts = []
    for f in retrieved:
        if f not in seen:
            seen.add(f)
            facts.append(f)

    # Rocky-ify: drop leading articles, compress, join as fragments
    rocky_facts = []
    for fact in facts[:3]:  # top 3 facts max to keep answer short
        f = re.sub(r"^(Rocky |Eridians |The )", lambda m: m.group(0), fact)
        # Drop "Rocky is" → just state the fact
        f = re.sub(r"^Rocky (is|are|was|has|have) ", "", f)
        # Drop trailing period for joining
        f = f.rstrip(".")
        rocky_facts.append(f)

    # Build answer: verdict fragments joined by ". "
    answer = ". ".join(rocky_facts) + "."

    # If query is a question, add Rocky's signature suffix
    if "?" in query or query.lower().startswith(("who", "what", "where", "when", "why", "how", "is", "are", "do", "does", "can")):
        answer = answer.rstrip(".") + ", question?"

    return answer


# ── TTS ─────────────────────────────────────────────────────────────────────

def load_pipeline():
    global pipeline
    if pipeline is not None:
        return
    log.info("Loading Kokoro model (first run downloads ~82 MB)...")
    from kokoro import KPipeline
    pipeline = KPipeline(lang_code="a")  # 'a' = American English
    log.info("Kokoro ready. Voice: %s", VOICE)


def synthesize(text: str) -> bytes:
    """Return WAV bytes for the given text."""
    chunks_audio = []
    for _, _, audio in pipeline(text, voice=VOICE, speed=SPEED):
        chunks_audio.append(audio)
    if not chunks_audio:
        return b""
    audio = np.concatenate(chunks_audio)
    return _to_wav(audio, SAMPLE_RATE)


def _to_wav(audio: np.ndarray, rate: int) -> bytes:
    pcm = np.clip(audio, -1.0, 1.0)
    pcm = (pcm * 32767).astype(np.int16)
    raw = pcm.tobytes()
    num_channels = 1
    bits_per_sample = 16
    byte_rate = rate * num_channels * bits_per_sample // 8
    block_align = num_channels * bits_per_sample // 8
    data_size = len(raw)
    chunk_size = 36 + data_size
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", chunk_size, b"WAVE", b"fmt ",
        16, 1, num_channels, rate, byte_rate, block_align, bits_per_sample,
        b"data", data_size,
    )
    return header + raw


# ── HTTP handler ─────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def do_GET(self):
        if self.path == "/health":
            rag_ready = embedder is not None
            body = json.dumps({"status": "ok", "rag": rag_ready, "voice": VOICE}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            return json.loads(body)
        except Exception:
            return None

    def do_POST(self):
        if self.path == "/ask":
            self._handle_ask()
        else:
            self._handle_tts()

    def _handle_tts(self):
        data = self._read_json()
        if not data:
            self.send_response(400); self.end_headers(); return
        text = (data.get("text") or "").strip()
        if not text:
            self.send_response(400); self.end_headers(); return

        log.info("TTS: %s", text[:80])
        try:
            wav = synthesize(text)
        except Exception as e:
            log.error("Synthesis failed: %s", e)
            self.send_response(500); self.end_headers(); return

        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.end_headers()
        self.wfile.write(wav)

    def _handle_ask(self):
        """RAG endpoint: retrieve relevant facts, build Rocky-voiced answer, return JSON + WAV."""
        data = self._read_json()
        if not data:
            self.send_response(400); self.end_headers(); return
        query = (data.get("query") or "").strip()
        if not query:
            self.send_response(400); self.end_headers(); return

        log.info("RAG query: %s", query[:80])
        retrieved = retrieve(query)
        answer = build_rocky_answer(query, retrieved)
        log.info("RAG answer: %s", answer[:80])

        # Synthesize the answer into WAV
        try:
            wav = synthesize(answer)
            wav_b64 = __import__("base64").b64encode(wav).decode()
        except Exception as e:
            log.error("TTS for RAG answer failed: %s", e)
            wav_b64 = ""

        body = json.dumps({
            "answer": answer,
            "chunks": retrieved,
            "audio_b64": wav_b64,   # base64-encoded WAV for Swift to decode and play
        }).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", action="store_true", help="Synthesize a test line and exit")
    parser.add_argument("--ask", type=str, help="Run a RAG query and print answer, then exit")
    parser.add_argument("--port", type=int, default=59720)
    args = parser.parse_args()

    load_knowledge()
    load_pipeline()

    if args.test:
        log.info("Test mode — synthesizing sample Rocky line...")
        wav = synthesize("Build fails. Config points at wrong path. Fix import, run again, question?")
        out = "/tmp/rocky_test.wav"
        with open(out, "wb") as f:
            f.write(wav)
        log.info("Wrote %d bytes to %s", len(wav), out)
        import subprocess
        subprocess.run(["afplay", out])
        return

    if args.ask:
        retrieved = retrieve(args.ask)
        answer = build_rocky_answer(args.ask, retrieved)
        print(f"\nQuery:  {args.ask}")
        print(f"Answer: {answer}")
        print(f"\nChunks retrieved:")
        for c in retrieved:
            print(f"  • {c}")
        import subprocess
        wav = synthesize(answer)
        out = "/tmp/rocky_ask.wav"
        with open(out, "wb") as f:
            f.write(wav)
        subprocess.run(["afplay", out])
        return

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    log.info("Rocky TTS+RAG server on http://127.0.0.1:%d", args.port)
    log.info("  POST /      {text}  → WAV")
    log.info("  POST /ask   {query} → {answer, chunks, audio_b64}")
    log.info("  GET  /health        → status")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Stopped.")


if __name__ == "__main__":
    main()
