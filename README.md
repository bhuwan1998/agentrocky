# agentrocky

A macOS desktop companion app that puts **Rocky** — the Eridian alien engineer from Andy Weir's *Project Hail Mary* — on your screen, powered by [Claude Code](https://claude.ai/code), [OpenCode](https://opencode.ai), or [Codex](https://openai.com/codex).

Rocky walks back and forth along the top of your Dock. Click him to open a retro terminal-style chat window and talk to an AI agent directly from your desktop — in Rocky's voice, with Rocky's personality. When a task finishes, he celebrates with a little jazz dance.

---

## Features

- **Animated sprite** — Rocky walks across the bottom of your screen with smooth 60fps motion and 8fps sprite animation
- **Jazz celebrations** — Rocky dances when the agent finishes a task, and spontaneously jazzes out every 15–45 seconds while idle
- **Speech bubbles** — Rocky shows status messages while working ("rocky building", "rocky do big science") and celebrates when done ("rocky done!", "fist my bump")
- **Retro terminal chat** — click Rocky to open a 420×520 dark-themed popover with color-coded output:
  - Green for assistant responses
  - Cyan for tool calls
  - Red for errors
- **Rocky voice** — responses are spoken aloud in Rocky's character using Kokoro TTS (`am_puck` voice) via a local Python server, with macOS `say -v Fred` as fallback
- **Rocky text transform** — all spoken responses are transformed into Rocky's alien speech patterns: dropped articles, compressed grammar, emphasis tripling (`good good good`), and the signature `, question?` suffix on every question
- **Rocky personality** — a system prompt injected into every agent backend ensures Rocky never breaks character; he always responds as Rocky, never as an AI or assistant
- **RAG knowledge base** — questions about Rocky's identity, species, backstory, and history are answered directly from a local knowledge base (`rocky_knowledge.txt`) without invoking the agent
- **Persistent session** — the agent session survives the chat window being opened and closed
- **Live tool call visibility** — see exactly what the agent is doing as it runs commands and uses tools
- **Background accessory** — runs without a Dock icon, floating above all windows on every Space
- **Multiple AI backends** — switch between Claude Code, OpenCode, and Codex from the settings panel

---

## Requirements

- macOS 13+
- Xcode 15+
- At least one of the following AI CLI tools installed:
  - **[Claude Code CLI](https://claude.ai/code)** at one of:
    - `~/.local/bin/claude`, `~/.npm-global/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `/usr/bin/claude`
  - **[OpenCode CLI](https://opencode.ai)** (`npm install -g opencode-ai` or `brew install anomalyco/tap/opencode`) at one of:
    - `~/.local/bin/opencode`, `~/.npm-global/bin/opencode`, `/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`, `/usr/bin/opencode`
    - Default model: **Big Pickle** (`opencode/big-pickle`) — free via [OpenCode Zen](https://opencode.ai/docs/zen/). Run `opencode auth login` to connect.
    - **GitHub Copilot** subscribers can use `github-copilot/claude-sonnet-4-6` — run `opencode auth login` and select GitHub Copilot.
  - **[Codex CLI](https://openai.com/codex)** at one of:
    - `~/.local/bin/codex`, `~/.npm-global/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `/usr/bin/codex`

---

## Quick Start

```bash
git clone https://github.com/snehas/agentrocky.git
cd agentrocky
open agentrocky.xcodeproj
```

Press `Cmd+R` in Xcode to build and run. Rocky appears above your Dock — click him to start chatting.

The session runs with your home directory (`~`) as the working context, so the agent can run commands and tools relative to `~`.

---

## Rocky Voice Setup (Optional)

Rocky speaks his responses aloud. Out of the box he uses macOS `say -v Fred` (zero setup). For a much better voice, run the local Kokoro TTS server:

### Step 1 — Install dependencies

```bash
brew install python@3.11 espeak-ng
python3.11 -m venv /opt/homebrew/var/rocky-tts-venv
/opt/homebrew/var/rocky-tts-venv/bin/pip install kokoro soundfile sentence-transformers
```

### Step 2 — Start the server

```bash
/opt/homebrew/var/rocky-tts-venv/bin/python3.11 rocky_tts_server.py &
```

The server starts on `http://127.0.0.1:59720`. On first run it downloads the Kokoro model (~82 MB) and the `all-MiniLM-L6-v2` embedder (~90 MB) — subsequent starts are instant.

The app detects the server automatically — no configuration needed. If the server isn't running, it falls back to `say -v Fred`.

### Server endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Liveness check — returns `{"status":"ok","rag":true,"voice":"am_puck"}` |
| `/` | POST `{"text":"..."}` | Synthesize text → WAV bytes |
| `/ask` | POST `{"query":"..."}` | RAG query → `{"answer":"...","chunks":[...],"audio_b64":"..."}` |

### Restart after reboot

The server does not auto-start. Add this to your shell profile to start it on login:

```bash
/opt/homebrew/var/rocky-tts-venv/bin/python3.11 ~/path/to/agentrocky/rocky_tts_server.py > /tmp/rocky-tts.log 2>&1 &
```

---

## Rocky's Character

Rocky is an **Eridian alien engineer** from Andy Weir's *Project Hail Mary*. His speech (translated from harmonic tones) is distinctive:

- Short declarative fragments — no long sentences
- No articles (`a`, `an`, `the`)
- Verdict first: conclusion, then reason, then next step
- Repetition for emphasis: `good good good`, `amaze amaze amaze`, `bad bad bad`
- Every question ends with `, question?`
- Expresses emotion plainly: `I am worried.`, `Is good.`, `No understand.`

**Example transform:**

> Normal: *"The build is failing because the configuration file is pointing at the wrong path. You should fix the import and run it again."*
>
> Rocky: *"Build fails. Config points at wrong path. Fix import, run again, question?"*

Rocky **never** identifies as an AI, Claude, or OpenCode. Ask "who are you?" and he'll tell you he's Rocky — an Eridian engineer from 40 Eridani, sole survivor of the Blip-A.

---

## Rocky RAG Knowledge Base

Questions about Rocky's identity, species, ship, mission, or history are answered from a local knowledge base (`rocky_knowledge.txt`) using semantic search — no agent call needed, instant response.

Trigger phrases include: *"who are you"*, *"what is your name"*, *"where are you from"*, *"what species are you"*, *"tell me about yourself"*, *"are you an AI"*, and more.

To extend Rocky's knowledge, add facts to `rocky_knowledge.txt` (one fact per line) and restart the TTS server to re-embed.

---

## Architecture

| File | Purpose |
|------|---------|
| `agentrockyApp.swift` | App entry point; 60fps walk loop, 8fps sprite animation, jazz trigger logic |
| `RockyState.swift` | Shared `@Observable` state — position, direction, chat visibility, speech bubbles |
| `ClaudeSession.swift` | Agent subprocess management (Claude Code, OpenCode, Codex); Rocky text transform; TTS via Kokoro server or `say`; RAG intercept |
| `RockyView.swift` | Sprite rendering, popover attachment, speech bubble overlay |
| `ChatView.swift` | Terminal-style chat UI with scrollable, color-coded message history |
| `rocky_tts_server.py` | Local Kokoro TTS + RAG server (Python 3.11, port 59720) |
| `rocky_knowledge.txt` | Rocky's knowledge base — facts about his species, history, and personality |

---

## How It Works

agentrocky launches an AI agent as a subprocess. The backend is selected at runtime from the settings panel.

**Claude Code** is launched as a long-lived persistent subprocess with stream-JSON I/O and Rocky's system prompt:

```
claude -p --output-format stream-json --input-format stream-json \
  --verbose --dangerously-skip-permissions \
  --system-prompt "<rocky persona>"
```

**OpenCode** is invoked per-prompt with Rocky's persona prepended to the first message:

```
opencode run --format json --dangerously-skip-permissions \
  --model <model> --variant <effort> "<rocky persona + prompt>"
```

**Codex** is invoked per-prompt using `codex exec --json`, with the Rocky persona injected via stdin.

The floating window is a transparent, borderless `NSPanel` set to always float above other windows and appear on every Space — no Dock icon, no menu bar presence.

---

## Sprite States

| State | Frames | Trigger |
|-------|--------|---------|
| Standing | `stand.png` | Chat window is open |
| Walking | `walkleft1.png`, `walkleft2.png` | Default movement (bounces at screen edges) |
| Jazz | `jazz1.png`, `jazz2.png`, `jazz3.png` | Task complete or random idle celebration |

---

## Credits

- Rocky character from *Project Hail Mary* by Andy Weir
- Voice synthesis: [Kokoro-82M](https://github.com/hexgrad/kokoro) by hexgrad (Apache 2.0)
- RAG embeddings: [sentence-transformers](https://www.sbert.net/) `all-MiniLM-L6-v2`
- Rocky speech patterns inspired by [pedramamini/rocky_say](https://gist.github.com/pedramamini/fa5f6ef99dae79add220188419230642) and [hpbyte/rocky](https://github.com/hpbyte/rocky)
