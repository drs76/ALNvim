# Pi agent setup (per machine) — for `:ALPi`

`:ALPi` opens the [Pi](https://pi.dev) coding agent in a terminal split, pointed at an
Ollama server (local or remote). Do this once per machine. For `:ALClaude` you only
need the `claude` CLI installed + logged in — nothing below.

Replace `<OLLAMA_URL>` with your server's OpenAI-compatible base, e.g.
`http://localhost:11434/v1` (local) or `https://ollama.example.lan:11443/v1` (remote proxy).

> **WSL note:** run every step below *inside* the WSL Linux shell. WSL's Node,
> DNS resolver, and CA trust store are all separate from Windows — a tool, host, or
> certificate that works in Windows is invisible to Pi (a Linux Node process) in WSL.

## 1. Node ≥ 22.19 (Pi requires it)
`node --version`; if < 22, on Debian/Ubuntu (incl. WSL):
```sh
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

## 2. Install Pi
```sh
curl -fsSL https://pi.dev/install.sh | sh        # interactive installer
# or, no sudo:
npm config set prefix ~/.npm-global
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
grep -q npm-global/bin ~/.bashrc || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
```
Verify: `pi --version`.

## 3. Ollama provider extension
```sh
mkdir -p ~/.pi
cat > ~/.pi/ollama-provider.ts <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
const mk = (id: string, name: string) => ({
  id, name, reasoning: false, input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 32768, maxTokens: 8192,
});
export default function (pi: ExtensionAPI) {
  pi.registerProvider("ollama", {
    baseUrl: "<OLLAMA_URL>",       // e.g. http://localhost:11434/v1
    apiKey: "ollama",
    api: "openai-completions",
    models: [
      mk("qwen2.5-coder:32b", "Qwen2.5 Coder 32B"),
      // add your own models...
    ],
  });
}
EOF
```

## 4. Register the extension (so a bare `pi` and `:ALPi` see the models)
```sh
pi install ~/.pi/ollama-provider.ts   # adds it to Pi's settings
pi list                               # confirm it's listed
```
Without this, the provider only loads when you pass `-e ~/.pi/ollama-provider.ts`,
so a bare `pi` (and `:ALPi`) reports **"No models available"**. After `install`,
both work; `-e <path>` still works as a one-off override.

## 5. TLS (only if your Ollama URL is HTTPS with a self-signed / private-CA cert)
Node uses its own CA bundle, not the OS/browser store, so a private-CA endpoint
fails with "Connection error". Either trust the CA, or skip verification:

- **Trust the CA (recommended):** install your CA's public cert into the OS store —
  on WSL this means the *WSL* trust store, not Windows':
  `sudo cp your-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`,
  then set `pi_env = { NODE_OPTIONS = "--use-system-ca" }` (Node ≥ 22).
- **Skip verification (LAN-only, insecure):** `pi_env = { NODE_TLS_REJECT_UNAUTHORIZED = "0" }`.

## 6. ALNvim config (in your private nvim config, not this repo)
```lua
require("al").setup({
  agent = {
    pi_provider = "~/.pi/ollama-provider.ts",
    pi_model    = "ollama/qwen2.5-coder:32b",
    -- pi_cmd   = { "pi", ... },                    -- full override
    -- pi_env   = { NODE_OPTIONS = "--use-system-ca" },
  },
  -- ghost = { endpoint = "<host>:11434", model = "qwen2.5-coder", insecure = false },
})
```

## Verify
After `pi install` (step 4) the provider is registered, so no `-e` is needed:
```sh
pi --list-models
pi --model ollama/qwen2.5-coder:32b -p --no-session "Reply with: PI-OK"
```
Or force-load a specific extension file as a one-off (works with or without install):
```sh
pi -e ~/.pi/ollama-provider.ts --list-models
```
A remote server's first call cold-loads the model — if you front Ollama with a
reverse proxy, raise its read timeout (e.g. nginx `proxy_read_timeout 600s`) or
large models will 504 on cold start. Then in an AL buffer: `<leader>ak`.

## WSL notes
- **Remote hostname must resolve inside WSL.** Check `getent hosts <host>`. WSL2 does
  not always inherit the Windows LAN resolver (esp. `.home.arpa`/`.lan` names served
  by a local DNS box), so a host that pings from Windows may fail in WSL. If it fails,
  add it to `/etc/hosts`, or fix DNS via `/etc/resolv.conf` / `wsl.conf`.
- **`--use-system-ca` needs Node ≥ 22** (the required version) and reads the *WSL*
  CA store — install the private CA there (step 5), not just in Windows.
- Clock skew inside a resumed WSL VM can break TLS ("certificate not yet valid");
  if you see cert errors after the laptop sleeps, resync the WSL clock.
