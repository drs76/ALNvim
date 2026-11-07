-- JSON write helpers.
--
-- vim.fn.json_encode emits everything on one line. Several files ALNvim writes
-- are user-facing and hand-maintained — ~/.claude/settings.json and the
-- per-project .vscode/alnvim.json — so encoding straight to disk silently
-- flattens whatever formatting the user had. M.write() re-indents first.
--
-- The formatter works on the *encoder's output* rather than walking the Lua
-- table, because a Lua table cannot reliably distinguish an empty object from an
-- empty array (json_decode maps {} to vim.empty_dict() and [] to {}); the
-- encoder has already made that decision correctly.

local M = {}

-- Re-indent a compact JSON string with two-space indentation.
-- Whitespace outside string literals is discarded and regenerated.
function M.pretty(s)
  local out    = {}
  local indent = 0
  local in_str = false
  local esc    = false

  local function nl()
    out[#out + 1] = "\n" .. string.rep("  ", indent)
  end

  -- Index of the next non-space character at or after i (0 if none).
  local function peek(i)
    local j = s:find("[^ \t\n\r]", i)
    return j and s:sub(j, j) or ""
  end

  local i = 1
  while i <= #s do
    local c = s:sub(i, i)

    if in_str then
      out[#out + 1] = c
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == '"' then
        in_str = false
      end

    elseif c == '"' then
      in_str = true
      out[#out + 1] = c

    elseif c == "{" or c == "[" then
      out[#out + 1] = c
      local nxt = peek(i + 1)
      -- Keep empty containers on one line: {} / []
      if nxt ~= "}" and nxt ~= "]" then
        indent = indent + 1
        nl()
      end

    elseif c == "}" or c == "]" then
      -- The matching open brace already suppressed its newline for the empty
      -- case, so only unindent when this container actually had content.
      local prev = out[#out] or ""
      if prev == "{" or prev == "[" then
        out[#out + 1] = c
      else
        indent = indent - 1
        nl()
        out[#out + 1] = c
      end

    elseif c == "," then
      out[#out + 1] = c
      nl()

    elseif c == ":" then
      out[#out + 1] = ": "

    elseif c:match("[ \t\n\r]") then
      -- insignificant whitespace between tokens — regenerated above

    else
      out[#out + 1] = c
    end

    i = i + 1
  end

  return table.concat(out)
end

-- Encode `data` and write it to `path` as indented JSON.
-- Creates the parent directory. Returns true on success, false plus an error.
function M.write(path, data)
  local ok, encoded = pcall(vim.fn.json_encode, data)
  if not ok then return false, encoded end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local lines = vim.split(M.pretty(encoded), "\n", { plain = true })
  local ok2, err = pcall(vim.fn.writefile, lines, path)
  if not ok2 then return false, err end
  return true
end

-- Decode JSON with comments and trailing commas, which VS Code allows in its
-- settings files and json_decode rejects. Returns nil when still invalid.
function M.decode_jsonc(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' then
      local j = i + 1
      while j <= n and text:sub(j, j) ~= '"' do
        j = j + (text:sub(j, j) == "\\" and 2 or 1)
      end
      out[#out + 1] = text:sub(i, j)
      i = j + 1
    elseif text:sub(i, i + 1) == "//" then
      i = (text:find("\n", i, true) or n + 1)
    elseif text:sub(i, i + 1) == "/*" then
      local _, e = text:find("*/", i + 2, true)
      i = (e or n) + 1
    else
      if c == "]" or c == "}" then
        -- Drop a trailing comma; a comment may have sat between it and here.
        local k = #out
        while k > 0 and out[k]:match("^%s$") do k = k - 1 end
        if out[k] == "," then out[k] = "" end
      end
      out[#out + 1] = c
      i = i + 1
    end
  end
  local ok, data = pcall(vim.fn.json_decode, table.concat(out))
  return ok and data or nil
end

return M
