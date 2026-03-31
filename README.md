# Ollama Code Assistant — Roblox Studio Plugin

An AI-powered Roblox scripting assistant that runs **100% locally and for free** using Ollama.

-----

## What’s Included

|File         |Purpose                         |
|-------------|--------------------------------|
|`init.lua`   |The Roblox Studio plugin itself |
|`proxy.js`   |Node.js bridge server (required)|
|`plugin.json`|Plugin metadata                 |

-----

## Why a Proxy?

Roblox Studio’s `HttpService` cannot make requests to `localhost` directly due to Roblox’s networking layer. The `proxy.js` script runs a tiny HTTP server on port 3000 that Studio *can* reach, and it forwards requests to Ollama on port 11434.

```
Roblox Studio → http://127.0.0.1:3000 → proxy.js → http://localhost:11434 → Ollama
```

-----

## Setup (One Time)

### Step 1 — Install Ollama

Download and install from **https://ollama.com**

Then pull a coding model (codellama is recommended for Roblox scripting):

```bash
ollama pull codellama:7b
```

Other good options:

```bash
ollama pull codellama:13b       # better quality, needs ~8GB RAM
ollama pull deepseek-coder:6.7b # very strong for code
ollama pull llama3:8b           # good all-rounder
ollama pull mistral:7b          # fast and capable
```

Start Ollama (it may already auto-start):

```bash
ollama serve
```

-----

### Step 2 — Install Node.js

Download from **https://nodejs.org** (LTS version).

The proxy uses **only built-in Node.js modules** — no `npm install` needed.

-----

### Step 3 — Start the Proxy

Open a terminal in the folder containing `proxy.js` and run:

```bash
node proxy.js
```

You should see:

```
╔══════════════════════════════════════════╗
║  Ollama Proxy running on port 3000       ║
╚══════════════════════════════════════════╝
```

**Leave this terminal open** while you use the plugin.

Optional arguments:

```bash
node proxy.js --port 4000                         # use a different port
node proxy.js --ollama http://localhost:11434      # custom Ollama URL
```

-----

### Step 4 — Install the Plugin in Roblox Studio

**Option A — Plugin file:**

1. Copy `init.lua` to `%LOCALAPPDATA%\Roblox\Plugins\OllamaAssistant.lua` (Windows)  
   or `~/Documents/Roblox/Plugins/OllamaAssistant.lua` (Mac)
1. Restart Roblox Studio

**Option B — Roblox Studio Plugin Manager:**

1. Open Roblox Studio
1. Go to **Plugins → Manage Plugins → Open Plugins Folder**
1. Create a folder called `OllamaAssistant`
1. Place `init.lua` and `plugin.json` inside it
1. Restart Studio

-----

### Step 5 — Enable HTTP in Studio

1. Open Roblox Studio
1. Go to **File → Game Settings → Security**
1. Enable **“Allow HTTP Requests”**

> ⚠️ This setting is per-game. You may need to enable it for each new place.

-----

## Using the Plugin

Click the **“Ollama AI”** button in the Studio toolbar to open the panel.

### ⌨ Code Tab

1. Type a description of what you want to script
1. Click **⚡ Generate**
1. Wait for the AI to respond (first run may be slow as the model loads)
1. Choose how to insert the code:
- **→ Selected Script** — appends to whichever Script/LocalScript is selected in the Explorer
- **+ Script** — creates a new Script in Workspace
- **+ Local** — creates a new LocalScript in Workspace
- **📝 Open in Script Editor** — creates a script and opens it immediately

**🔍 Explain Selection** — select a Script in the Explorer and click this to get an AI explanation of what it does.

### 💬 Chat Tab

Ask any Roblox scripting question in natural language. The chat retains context between messages (up to 10 exchanges).

### ⚙ Settings Tab

- **Proxy URL** — change if you’re using a different port (`node proxy.js --port 4000`)
- **Ollama Model** — switch models anytime (must be pulled first with `ollama pull <name>`)
- **Test Connection** — verifies the proxy and Ollama are both reachable
- Settings are saved between Studio sessions

-----

## Troubleshooting

|Problem                    |Fix                                                                       |
|---------------------------|--------------------------------------------------------------------------|
|`HTTP Error`               |Make sure proxy.js is running and HTTP is enabled in Game Settings        |
|`Cannot reach Ollama`      |Run `ollama serve` in a terminal                                          |
|`model not found`          |Run `ollama pull codellama:7b`                                            |
|Port 3000 in use           |Run `node proxy.js --port 3001` and update the proxy URL in Settings      |
|Slow first response        |Normal — Ollama loads the model on first use. Subsequent calls are faster.|
|Code inserts in wrong place|Select the target Script in the Explorer before clicking Insert           |

-----

## Tips for Best Results

- Be specific: *“A door that opens when any player touches it, closes after 3 seconds”* works better than *“a door”*
- Mention whether it should be a `Script` (server) or `LocalScript` (client)
- Ask follow-up questions in the Chat tab to refine code
- Use **Explain Selection** to understand unfamiliar scripts before editing them
- `codellama:13b` produces noticeably better Roblox code than `codellama:7b` if your machine can handle it

-----

## Privacy

Everything runs locally. No code or prompts are sent to any external server.
