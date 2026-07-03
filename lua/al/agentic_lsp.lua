-- Experimental agentic AL language server (`al launchlspserver`).
--
-- Uses the standard-LSP server shipped by the Microsoft AL Development Tools
-- dotnet tool (BC 2026 release wave 1+) instead of the VSCode extension's
-- EditorServices.Host binary. Because it speaks *standard* LSP over stdio, none
-- of the EditorServices custom-protocol workarounds in plugin/al.lua apply:
-- native textDocument/definition, find-references, rename, and completion all
-- work directly. It is started as a distinct client name (al_agentic_lsp) so the
-- EditorServices-specific LspAttach/handler code (guarded on the
-- "al_language_server" name) is skipped entirely.
--
-- Enable via require("al").setup({ experimental_lsp = true }).
-- Coexists with the AL MCP server — both are the same `al` binary, different
-- subcommands (launchlspserver vs launchmcpserver).

local M = {}

local platform = require("al.platform")

-- PIDs of agentic servers started this session — VimLeavePre kills the whole
-- .NET process tree on exit (mirrors _al_server_pids for EditorServices).
M.pids = {}

-- Resolve the `al` dotnet tool binary (~/.dotnet/tools/al[.exe]).
function M.binary()
  local base = vim.fn.expand("~/.dotnet/tools/al")
  return platform.is_windows and (base .. ".exe") or base
end

-- True if the al binary exists AND exposes launchlspserver (older tool versions
-- only have launchmcpserver).
function M.available()
  local bin = M.binary()
  if vim.fn.executable(bin) == 0 then return false end
  local out = vim.fn.system({ bin, "--help" })
  return out:find("launchlspserver", 1, true) ~= nil
end

-- Start the agentic LSP for `root`, attaching buffer `bufnr`.
function M.start(bufnr, root)
  local bin = M.binary()
  if vim.fn.executable(bin) == 0 then
    vim.notify(
      "AL agentic LSP: al binary not found at " .. bin
      .. "\nInstall/update with: dotnet tool update "
      .. "Microsoft.Dynamics.BusinessCentral.Development.Tools --prerelease --global",
      vim.log.levels.ERROR)
    return
  end

  local cfg   = require("al").config
  local cache = root .. "/" .. (cfg.packagecachepath or ".alpackages")

  -- Positional <root> enables single-project resolution; --packagecachepath points
  -- at the .app symbol packages the server needs for full language intelligence.
  local cmd = {
    bin, "launchlspserver", root,
    "--packagecachepath", cache,
    "--disableTelemetry",
  }
  -- A .vscode/settings.json (if present) supplies al.* keys the server honours.
  local vscode_settings = root .. "/.vscode/settings.json"
  if vim.fn.filereadable(vscode_settings) == 1 then
    vim.list_extend(cmd, { "--settingspath", vscode_settings })
  end
  if cfg.ruleset_path and cfg.ruleset_path ~= "" then
    vim.list_extend(cmd, { "--ruleset", cfg.ruleset_path })
  end

  vim.lsp.start({
    name     = "al_agentic_lsp",
    cmd      = cmd,
    root_dir = root,
    on_init  = function(client)
      -- vim syntax file (syntax/al.vim) owns highlighting; drop semantic tokens
      -- so the server's classification doesn't override it (same reason as the
      -- EditorServices path).
      client.server_capabilities.semanticTokensProvider = nil
      pcall(function()
        local pid = client.rpc.handle:get_pid()
        if pid and pid > 0 then M.pids[pid] = true end
      end)
    end,
    on_attach = function(client, buf)
      local status = require("al.status")
      -- Standard LSP: no al/progressNotification or al/activeProjectLoaded events,
      -- so surface project identity and mark ready immediately.
      local app = require("al.lsp").read_app_json(root)
      if app then status.set_project(app.name, app.version, root) end
      status.set_lsp_ready()

      -- Auto-configure the AL MCP server once per client (the EditorServices
      -- LspAttach path that normally does this is skipped in agentic mode).
      if cfg.auto_mcp and not client._al_mcp_configured then
        client._al_mcp_configured = true
        require("al.mcp").configure(root)
      end

      -- Force native go-to-definition. vim.schedule defers past the user's own
      -- generic LspAttach handler so this buffer-local map wins.
      vim.schedule(function()
        vim.keymap.set("n", "gd", vim.lsp.buf.definition,
          { buffer = buf, desc = "AL: Go to definition" })
      end)

      if type(cfg.on_attach) == "function" then
        pcall(cfg.on_attach, client, buf)
      end
    end,
  }, { bufnr = bufnr })
end

return M
