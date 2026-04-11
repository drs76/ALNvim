-- lua/al/namespace.lua
-- Namespace wizard: adds `namespace <ns>;` to all AL source files that don't
-- already have one, then optionally applies source.organizeImports via the LSP
-- to add the resulting missing `using` statements.
local M = {}

local lsp      = require("al.lsp")
local platform = require("al.platform")

-- Strip characters that are not valid in an AL namespace identifier segment.
-- AL identifiers: letters, digits, underscores only (no spaces or symbols).
function M.sanitize_name(str)
  if not str then return "" end
  return (str:gsub("[^%w_]", ""))
end

-- Build a namespace suggestion from app.json: "Publisher.AppName"
function M.suggest_namespace(root)
  local app = lsp.read_app_json(root)
  if not app then return "" end
  local pub  = M.sanitize_name(app.publisher or "")
  local name = M.sanitize_name(app.name or "")
  if pub == "" and name == "" then return "" end
  if pub == "" then return name end
  if name == "" then return pub end
  return pub .. "." .. name
end

-- Return true if the file already has a namespace declaration in its first 10 lines.
function M.has_namespace(path)
  local f = io.open(path, "r")
  if not f then return false end
  local found = false
  local i = 0
  for line in f:lines() do
    i = i + 1
    if i > 10 then break end
    if line:match("^%s*namespace%s+%S") then
      found = true
      break
    end
  end
  f:close()
  return found
end

-- Add `namespace <ns>;` to the top of a single file.
-- Returns true if added, false if skipped (already had one or unreadable).
function M.add_namespace_to_file(path, ns)
  if M.has_namespace(path) then return false end
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  -- Normalise line endings to LF.
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local new_content = "namespace " .. ns .. ";\n\n" .. content
  local fw = io.open(path, "w")
  if not fw then return false end
  fw:write(new_content)
  fw:close()
  return true
end

-- Add namespace to all AL source files in the project.
-- Returns { added = {path, ...}, skipped = N }
function M.add_namespace_to_project(root, ns)
  local files   = platform.glob_al_files(root)
  local added   = {}
  local skipped = 0
  for _, path in ipairs(files) do
    if M.add_namespace_to_file(path, ns) then
      table.insert(added, path)
    else
      skipped = skipped + 1
    end
  end
  return { added = added, skipped = skipped }
end

-- Apply source.organizeImports to a single buffer (already loaded).
-- Calls on_done() when finished (success or failure).
local function apply_organize_imports(bufnr, on_done)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "al_language_server" })
  if #clients == 0 then
    if on_done then on_done() end
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 0 },
    },
    context = { only = { "source.organizeImports" }, diagnostics = {} },
  }

  vim.lsp.buf_request(bufnr, "textDocument/codeAction", params, function(err, result)
    if not err and result and #result > 0 then
      local action = result[1]
      if action.edit then
        vim.lsp.util.apply_workspace_edit(action.edit, "utf-8")
      elseif action.command then
        local cmd = type(action.command) == "table" and action.command or action
        vim.lsp.buf.execute_command(cmd)
      end
      -- Save silently so the using statements are persisted.
      pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd("silent! write") end)
    end
    if on_done then on_done() end
  end)
end

-- Sequentially apply source.organizeImports to each file in the list.
-- Shows progress notifications. Calls on_done() when all files are processed.
function M.fix_usings(files, on_done)
  local total = #files
  if total == 0 then
    if on_done then on_done() end
    return
  end

  local function process(idx)
    if idx > total then
      vim.notify(string.format("AL: using statements applied to %d file(s)", total),
        vim.log.levels.INFO)
      if on_done then on_done() end
      return
    end

    local path = files[idx]
    vim.notify(string.format("AL: fixing usings [%d/%d] %s",
      idx, total, vim.fn.fnamemodify(path, ":t")), vim.log.levels.INFO)

    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)

    -- Give the LSP 600 ms to process textDocument/didOpen before requesting
    -- code actions. The server needs to analyse the file first.
    vim.defer_fn(function()
      apply_organize_imports(buf, function()
        process(idx + 1)
      end)
    end, 600)
  end

  process(1)
end

-- Interactive wizard: prompt for namespace, add to all eligible files,
-- optionally fix using statements via LSP.
function M.wizard(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: no project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  -- Pre-scan to find candidates.
  local all_files = platform.glob_al_files(root)
  if #all_files == 0 then
    vim.notify("AL: no AL source files found in " .. root, vim.log.levels.WARN)
    return
  end

  local candidates = {}
  for _, path in ipairs(all_files) do
    if not M.has_namespace(path) then
      table.insert(candidates, path)
    end
  end

  if #candidates == 0 then
    vim.notify("AL: all files already have a namespace — nothing to do", vim.log.levels.INFO)
    return
  end

  -- Prompt for namespace, pre-filled with Publisher.AppName.
  local suggestion = M.suggest_namespace(root)
  vim.ui.input({
    prompt  = string.format("Namespace for %d file(s) [Publisher.AppName]: ", #candidates),
    default = suggestion,
  }, function(ns)
    if not ns or ns == "" then
      vim.notify("AL: namespace wizard cancelled", vim.log.levels.WARN)
      return
    end

    -- Confirm.
    vim.ui.select(
      { string.format("Yes — add namespace to %d file(s)", #candidates), "Cancel" },
      { prompt = "Add namespace '" .. ns .. "'?" },
      function(choice)
        if not choice or choice == "Cancel" then
          vim.notify("AL: namespace wizard cancelled", vim.log.levels.WARN)
          return
        end

        -- Add namespace declarations.
        local result = M.add_namespace_to_project(root, ns)

        -- Reload any already-open buffers so Neovim sees the changes on disk.
        for _, path in ipairs(result.added) do
          local existing_buf = vim.fn.bufnr(path)
          if existing_buf ~= -1 and vim.api.nvim_buf_is_loaded(existing_buf) then
            vim.api.nvim_buf_call(existing_buf, function()
              vim.cmd("silent! edit")
            end)
          end
        end

        vim.notify(string.format(
          "AL: namespace '%s' added to %d file(s) (%d already had one)",
          ns, #result.added, result.skipped), vim.log.levels.INFO)

        if #result.added == 0 then return end

        -- Offer to apply using statements via LSP.
        vim.ui.select(
          { "Yes — apply using statements now (via LSP)", "No — I'll use <leader>acn per file" },
          { prompt = "Add missing using statements?" },
          function(fix_choice)
            if fix_choice and fix_choice:match("^Yes") then
              -- Trigger re-analysis first so the server picks up the new namespaces.
              local cops = require("al.cops")
              cops.apply(root, cops.get_active(root), true)
              -- Then fix usings after a short pause for the server to re-index.
              vim.defer_fn(function()
                M.fix_usings(result.added, function()
                  -- Final re-analysis to clear any residual diagnostics.
                  cops.apply(root, cops.get_active(root), true)
                end)
              end, 2000)
            else
              vim.notify(
                "AL: use <leader>acn (organise namespaces) on each file to add using statements",
                vim.log.levels.INFO)
            end
          end
        )
      end
    )
  end)
end

return M
