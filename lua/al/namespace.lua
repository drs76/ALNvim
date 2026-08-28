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

-- Return the loaded buffer for `path`, or nil when the file is not open.
local function loaded_buf(path)
  local b = vim.fn.bufnr(path)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then return b end
  return nil
end

-- Add `namespace <ns>;` to the top of a single file.
-- Returns "added", "skipped" (already namespaced / unreadable), or "modified"
-- (open with unsaved changes — see add_namespace_to_project).
function M.add_namespace_to_file(path, ns)
  if M.has_namespace(path) then return "skipped" end

  -- Refuse to touch a file whose buffer has unsaved changes. This function
  -- writes with io.open, behind Neovim's back; the caller then reloads the
  -- buffer. On a modified buffer that reload fails with E37 (swallowed by
  -- `silent!`), leaving the buffer holding pre-namespace content that the
  -- user's next :w writes straight back over the namespace line.
  local buf = loaded_buf(path)
  if buf and vim.bo[buf].modified then return "modified" end

  local f = io.open(path, "r")
  if not f then return "skipped" end
  local content = f:read("*a")
  f:close()
  -- Normalise line endings to LF.
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local new_content = "namespace " .. ns .. ";\n\n" .. content
  local fw = io.open(path, "w")
  if not fw then return "skipped" end
  fw:write(new_content)
  fw:close()
  return "added"
end

-- Add namespace to all AL source files in the project.
-- Returns { added = {path, ...}, skipped = N, modified = {path, ...} }
-- `modified` lists files left untouched because they had unsaved changes.
function M.add_namespace_to_project(root, ns)
  local files    = platform.glob_al_files(root)
  local added    = {}
  local modified = {}
  local skipped  = 0
  for _, path in ipairs(files) do
    local result = M.add_namespace_to_file(path, ns)
    if result == "added" then
      table.insert(added, path)
    elseif result == "modified" then
      table.insert(modified, path)
    else
      skipped = skipped + 1
    end
  end
  return { added = added, skipped = skipped, modified = modified }
end

-- Apply source.organizeImports to the current buffer via the LSP picker.
-- The picker is the only reliable path — manual buf_request_sync returns 0
-- actions regardless of params; the built-in code_action handler works.
function M.add_usings()
  vim.lsp.buf.code_action({ context = { only = { "source.organizeImports" } } })
end

-- fix_usings: batch organizeImports is not reliably achievable via LSP
-- for background buffers (server returns 0 actions without interactive context).
-- Notify the user to apply per-file with <leader>acn after the namespace wizard.
function M.fix_usings(files, on_done)
  if #files > 0 then
    vim.notify(
      string.format("AL: open each file and use <leader>acn to add missing using statements (%d file(s) affected)", #files),
      vim.log.levels.INFO)
  end
  if on_done then on_done() end
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
        -- edit! is safe here: add_namespace_to_file refuses to write a file
        -- whose buffer is modified, so nothing unsaved can be discarded.
        for _, path in ipairs(result.added) do
          local existing_buf = loaded_buf(path)
          if existing_buf then
            vim.api.nvim_buf_call(existing_buf, function()
              vim.cmd("silent! edit!")
            end)
          end
        end

        vim.notify(string.format(
          "AL: namespace '%s' added to %d file(s) (%d already had one)",
          ns, #result.added, result.skipped), vim.log.levels.INFO)

        if #result.modified > 0 then
          vim.notify(string.format(
            "AL: %d file(s) skipped — unsaved changes. Save them and re-run :ALAddNamespace:\n  %s",
            #result.modified,
            table.concat(vim.tbl_map(function(p)
              return vim.fn.fnamemodify(p, ":~:.")
            end, result.modified), "\n  ")), vim.log.levels.WARN)
        end

        if #result.added == 0 then return end

        vim.notify(
          "AL: open each file and use <leader>acn to add missing using statements",
          vim.log.levels.INFO)
      end
    )
  end)
end

return M
