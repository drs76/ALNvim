-- AL Go! — create a new AL project from scratch (mirrors VSCode al.go command).
-- M.new_project()  →  :ALNewProject
local M = {}

local RUNTIMES = {
  { label = "18.0  BC 2026 release wave 2 (latest)", runtime = "18.0", application = "29.0.0.0" },
  { label = "17.0  BC 2026 release wave 1",          runtime = "17.0", application = "28.0.0.0" },
  { label = "16.0  BC 2025 release wave 2",          runtime = "16.0", application = "27.0.0.0" },
  { label = "15.0  BC 2025 release wave 1",          runtime = "15.0", application = "26.0.0.0" },
  { label = "14.0  BC 2024 release wave 2",          runtime = "14.0", application = "25.0.0.0" },
  { label = "13.0  BC 2024 release wave 1",          runtime = "13.0", application = "24.0.0.0" },
  { label = "12.0  BC 2023 release wave 2",          runtime = "12.0", application = "23.0.0.0" },
  { label = "11.0  BC 2023 release wave 1",          runtime = "11.0", application = "22.0.0.0" },
  { label = "10.0  BC 2023 release wave 1 (LTSC)",   runtime = "10.0", application = "21.0.0.0" },
}

-- Seed once per session, not per call. Reseeding from the clock on every call
-- makes the sequence a function of the time the call happened: two processes
-- started in the same second with comparable CPU time draw the same numbers.
-- This is the app.json `id`, and BC rejects two extensions claiming one ID.
math.randomseed(os.time())

-- One random nibble. Prefers libuv's CSPRNG; math.random is the fallback for a
-- build where uv.random is missing or fails (it needs entropy from the OS).
local function nibble()
  local ok, bytes = pcall(vim.uv.random, 1)
  if ok and type(bytes) == "string" and #bytes == 1 then
    return bytes:byte() % 16
  end
  return math.random(0, 15)
end

local function gen_uuid()
  -- Parenthesised: gsub returns (string, count), and an unparenthesised call
  -- in the last argument position would pass the count on to string.format.
  return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    -- y is the RFC 4122 variant nibble: one of 8, 9, a, b.
    local v = c == "x" and nibble() or (8 + nibble() % 4)
    return ("%x"):format(v)
  end))
end

-- Returns the first non-existing path: base, base2, base3, …
local function next_available(base)
  if vim.fn.isdirectory(base) == 0 and vim.fn.filereadable(base) == 0 then return base end
  local i = 2
  while vim.fn.isdirectory(base .. i) ~= 0 or vim.fn.filereadable(base .. i) ~= 0 do
    i = i + 1
  end
  return base .. i
end

local function js_str(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Where the starter object lands. Must agree with wizard.build_path's
-- src/<obj_type>/<Name>.<FileType>.al, or organise_file moves it on first save.
local HELLO_WORLD_PATH = "src/pageextension/CustomerListExt.PageExt.al"

-- writefile() takes lines; the templates are format strings ending in \n, which
-- vim.split turns into a trailing empty element and an extra blank line on disk.
local function write_lines(path, content)
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  return vim.fn.writefile(lines, path)
end

local function build_app_json(name, publisher, rv, id_from)
  local id_to = id_from + 49
  return string.format([[{
  "id": "%s",
  "name": "%s",
  "publisher": "%s",
  "version": "1.0.0.0",
  "brief": "",
  "description": "",
  "privacyStatement": "",
  "EULA": "",
  "help": "",
  "url": "",
  "logo": "",
  "dependencies": [],
  "screenshots": [],
  "platform": "1.0.0.0",
  "application": "%s",
  "idRanges": [
    {
      "from": %d,
      "to": %d
    }
  ],
  "resourceExposurePolicy": {
    "allowDebugging": true,
    "allowDownloadingSource": true,
    "includeSourceInSymbolFile": true
  },
  "runtime": "%s",
  "features": [
    "NoImplicitWith"
  ]
}]],
    gen_uuid(),
    js_str(name),
    js_str(publisher),
    rv.application,
    id_from, id_to,
    rv.runtime
  )
end

-- Default launch.json mirroring VSCode's initializeCurrentFolder output.
-- Both the cloud-sandbox and on-prem stubs are included so the user only
-- needs to fill in their specific server details before launching/debugging.
local LAUNCH_JSON = [[{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Microsoft cloud sandbox",
      "request": "launch",
      "type": "al",
      "environmentType": "Sandbox",
      "environmentName": "sandbox",
      "startupObjectId": 22,
      "startupObjectType": "Page",
      "breakOnError": "All",
      "launchBrowser": true,
      "enableLongRunningSqlStatements": true,
      "enableSqlInformationDebugger": true
    },
    {
      "name": "Your own server",
      "request": "launch",
      "type": "al",
      "environmentType": "OnPrem",
      "server": "http://bcserver",
      "serverInstance": "BC",
      "authentication": "UserPassword",
      "startupObjectId": 22,
      "startupObjectType": "Page",
      "breakOnError": "All",
      "launchBrowser": true,
      "enableLongRunningSqlStatements": true,
      "enableSqlInformationDebugger": true,
      "tenant": "default"
    }
  ]
}]]

-- Publisher.Project with whitespace (and hyphens in the project) removed —
-- the starter object's namespace, and {{rootnamespace}} in extension templates.
local function root_namespace(name, publisher)
  local pub  = publisher:gsub("%s+", "")
  local proj = name:gsub("[%-%s]+", "")
  return (pub ~= "" and proj ~= "") and (pub .. "." .. proj) or "DefaultNamespace"
end

local function build_hello_world(name, publisher, rv, id_from)
  local header = "// Welcome to your new AL extension.\n"
    .. "// Remember that object names and IDs should be unique across all extensions.\n"
    .. "// AL snippets start with t*, like tpageext - give them a try and happy coding!\n"

  local ns_block = ""
  if tonumber(rv.runtime) >= 12 then
    ns_block = string.format("\nnamespace %s;\n\nusing Microsoft.Sales.Customer;\n",
      root_namespace(name, publisher))
  end

  return string.format(
    "%s%s\npageextension %d CustomerListExt extends \"Customer List\"\n"
    .. "{\n"
    .. "    trigger OnOpenPage();\n"
    .. "    begin\n"
    .. "        Message('App published: Hello world');\n"
    .. "    end;\n"
    .. "}\n",
    header, ns_block, id_from
  )
end

-- ── Extension templates ─────────────────────────────────────────────────────

-- The built-in starter (build_app_json + build_hello_world) is always offered
-- first, so :ALNewProject works with no VS Code extension installed.
local BUILTIN = {
  name        = "Hello World (built-in)",
  description = "app.json, launch.json and a starter page extension",
  builtin     = true,
  generate_app_json = true,
}

-- Templates shipped by the extension: <ext>/templates/*/altemplate.json.
-- ext_path defaults to the auto-detected extension; nil means none.
local function list_templates(ext_path)
  if ext_path == nil then
    local ok, ext = pcall(require, "al.ext")
    ext_path = ok and ext.path or nil
  end
  local out = { BUILTIN }
  if not ext_path or ext_path == "" then return out end
  local found = {}
  for _, f in ipairs(vim.fn.glob(ext_path .. "/templates/*/altemplate.json", false, true)) do
    local okr, lines = pcall(vim.fn.readfile, f)
    local meta = okr and require("al.json").decode_jsonc(table.concat(lines, "\n"))
    if type(meta) == "table" then
      found[#found + 1] = {
        name        = type(meta.name) == "string" and meta.name
                      or vim.fn.fnamemodify(f, ":h:t"),
        description = type(meta.description) == "string" and meta.description or "",
        dir         = vim.fn.fnamemodify(f, ":h"),
        generate_app_json = meta.generateAppJson ~= false,
      }
    end
  end
  table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
  vim.list_extend(out, found)
  return out
end

-- Replace template placeholders. vars:
--   id             first ID of the range: {{id+N}} → id + N
--   guids          memo table: {{guidK}} draws one gen_uuid() per K and reuses
--                  it, so {{guid0}} in app.json and in code match. Pass the
--                  same table for every file of one project.
--   projectname, publishername, rootnamespace
-- Unknown placeholders are left as they are.
local function substitute(text, vars)
  vars.guids = vars.guids or {}
  return (text:gsub("{{%s*([%w_]+)%s*([%+%-]?)%s*(%d*)%s*}}", function(key, op, num)
    local k = key:lower()
    if k == "id" and vars.id then
      local n = tonumber(num) or 0
      return tostring(op == "-" and vars.id - n or vars.id + n)
    end
    if op ~= "" then return nil end
    local gi = k:match("^guid(%d*)$")
    if gi then
      vars.guids[gi] = vars.guids[gi] or gen_uuid()
      return vars.guids[gi]
    end
    local v = vars[k]
    if type(v) == "string" then return v end
    return nil
  end))
end

-- Every file of a template, relative to dir. glob's ** does not descend into
-- dot-directories, so .resources (agent instructions, test datasets) needs its
-- own pass. altemplate.json is the template's metadata, not project content.
local function template_files(dir)
  local files, seen = {}, {}
  local function add(path)
    path = path:gsub("\\", "/")
    if vim.fn.isdirectory(path) == 1 or seen[path] then return end
    local rel = path:sub(#dir + 2)
    if rel == "altemplate.json" then return end
    seen[path] = true
    files[#files + 1] = rel
  end
  dir = dir:gsub("\\", "/")
  for _, f in ipairs(vim.fn.glob(dir .. "/**/*", false, true)) do add(f) end
  for _, d in ipairs(vim.fn.glob(dir .. "/.[^.]*", false, true)) do
    if vim.fn.isdirectory(d) == 1 then
      for _, f in ipairs(vim.fn.glob(d .. "/**/*", false, true)) do add(f) end
    else
      add(d)
    end
  end
  table.sort(files)
  return files
end

local function read_all(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function write_all(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "wb"); if not f then return false end
  f:write(content); f:close(); return true
end

-- Copy tpl into proj_dir with placeholders substituted. Byte-exact apart from
-- the substitutions (io, not readfile/writefile, so CRLF survives). Returns the
-- written relative paths.
--   opts: name, publisher, id_from, rv (runtime entry, for a generated app.json)
local function scaffold_template(tpl, proj_dir, opts)
  local vars = {
    id            = opts.id_from,
    projectname   = opts.name,
    publishername = opts.publisher,
    rootnamespace = root_namespace(opts.name, opts.publisher),
    guids         = {},
  }
  local written = {}
  for _, rel in ipairs(template_files(tpl.dir)) do
    if not (rel == "app.json" and tpl.generate_app_json) then
      local content = read_all(tpl.dir .. "/" .. rel)
      if content and write_all(proj_dir .. "/" .. rel, substitute(content, vars)) then
        written[#written + 1] = rel
      end
    end
  end
  if vim.fn.filereadable(proj_dir .. "/app.json") == 0 then
    write_lines(proj_dir .. "/app.json",
      build_app_json(opts.name, opts.publisher, opts.rv or RUNTIMES[1], opts.id_from))
    written[#written + 1] = "app.json"
  end
  return written
end

-- The file to open once a template is in place: its README, else the first
-- .al file.
local function first_file(proj_dir, written)
  for _, rel in ipairs(written) do
    if rel:lower() == "readme.md" then return proj_dir .. "/" .. rel end
  end
  for _, rel in ipairs(written) do
    if rel:match("%.al$") then return proj_dir .. "/" .. rel end
  end
  return proj_dir .. "/app.json"
end

function M.new_project()
  local default_parent = vim.fn.expand("~")

  vim.ui.input({ prompt = "Parent directory: ", default = default_parent, completion = "dir" }, function(parent)
    if not parent or parent == "" then return end
    parent = vim.fn.expand(parent):gsub("[/\\]$", "")

    local default_name = vim.fn.fnamemodify(next_available(parent .. "/ALProject"), ":t")
    vim.ui.input({ prompt = "Project name: ", default = default_name }, function(name)
      if not name or name == "" then return end

      -- name is concatenated into a path and is also the app.json "name".
      -- A separator or .. would put the project somewhere other than under the
      -- parent the user just chose.
      if name:find("[/\\]") or name:find("%.%.") then
        vim.notify("AL Go!: project name cannot contain path separators or '..'",
          vim.log.levels.ERROR)
        return
      end

      local proj_dir = parent .. "/" .. name
      if vim.fn.isdirectory(proj_dir) ~= 0 then
        vim.notify("AL Go!: directory already exists: " .. proj_dir, vim.log.levels.ERROR)
        return
      end

      local templates = list_templates()
      vim.ui.select(templates, {
        prompt = "Template:",
        format_item = function(t)
          return t.description ~= "" and (t.name .. "  — " .. t.description) or t.name
        end,
      }, function(tpl)
        if not tpl then return end

        local function ask_rest(rv)
          vim.ui.input({ prompt = "Publisher: ", default = "" }, function(publisher)
            if publisher == nil then return end  -- Esc = cancel; empty string is valid

            vim.ui.input({ prompt = "ID range start: ", default = "50100" }, function(id_str)
              if not id_str or id_str == "" then return end
              local id_from = tonumber(id_str)
              if not id_from or id_from < 0 then
                vim.notify("AL Go!: invalid ID range start", vim.log.levels.ERROR)
                return
              end

              vim.fn.mkdir(proj_dir .. "/.alpackages", "p")
              vim.fn.mkdir(proj_dir .. "/.vscode",     "p")

              local open_path
              if tpl.builtin then
                -- The starter object goes straight to its CRS home. Writing it at
                -- the project root — which is what VSCode's template does — means
                -- wizard.organise_file renames it out from under the user on the
                -- very first :w, since it runs on BufWritePost for every AL file
                -- under the root. HELLO_WORLD_PATH must match wizard.build_path.
                open_path = proj_dir .. "/" .. HELLO_WORLD_PATH
                vim.fn.mkdir(vim.fn.fnamemodify(open_path, ":h"), "p")
                write_lines(proj_dir .. "/app.json", build_app_json(name, publisher, rv, id_from))
                write_lines(open_path, build_hello_world(name, publisher, rv, id_from))
              else
                local written = scaffold_template(tpl, proj_dir, {
                  name = name, publisher = publisher, id_from = id_from, rv = rv,
                })
                open_path = first_file(proj_dir, written)
              end
              if vim.fn.filereadable(proj_dir .. "/.vscode/launch.json") == 0 then
                write_lines(proj_dir .. "/.vscode/launch.json", LAUNCH_JSON)
              end

              -- The ID cache is keyed per project+type and these writes fire no
              -- autocommands, so :ALNextId would not see the objects just created.
              pcall(function() require("al.ids").invalidate() end)

              vim.schedule(function()
                vim.cmd("edit " .. vim.fn.fnameescape(open_path))
                vim.notify(
                  string.format("AL Go!: project created → %s  (%s)", proj_dir, tpl.name),
                  vim.log.levels.INFO
                )
              end)
            end)
          end)
        end

        -- A template that ships its own app.json fixes the target platform;
        -- the runtime prompt only matters when app.json is generated.
        if not tpl.generate_app_json then return ask_rest(nil) end
        vim.ui.select(
          vim.tbl_map(function(r) return r.label end, RUNTIMES),
          { prompt = "Target platform:" },
          function(choice)
            if not choice then return end
            for _, r in ipairs(RUNTIMES) do
              if r.label == choice then return ask_rest(r) end
            end
          end
        )
      end)
    end)
  end)
end

-- Internals reached by tests/project_spec.lua only — never call from plugin code.
M._test = {
  gen_uuid          = gen_uuid,
  build_app_json    = build_app_json,
  build_hello_world = build_hello_world,
  write_lines       = write_lines,
  root_namespace    = root_namespace,
  substitute        = substitute,
  list_templates    = list_templates,
  template_files    = template_files,
  scaffold_template = scaffold_template,
  HELLO_WORLD_PATH  = HELLO_WORLD_PATH,
  RUNTIMES          = RUNTIMES,
}

return M
