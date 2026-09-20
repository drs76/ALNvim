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
  "showMyCode": true,
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

local function build_hello_world(name, publisher, rv, id_from)
  local header = "// Welcome to your new AL extension.\n"
    .. "// Remember that object names and IDs should be unique across all extensions.\n"
    .. "// AL snippets start with t*, like tpageext - give them a try and happy coding!\n"

  local ns_block = ""
  if tonumber(rv.runtime) >= 12 then
    local pub  = publisher:gsub("%s+", "")
    local proj = name:gsub("[%-%s]+", "")
    local ns   = (pub ~= "" and proj ~= "") and (pub .. "." .. proj) or "DefaultNamespace"
    ns_block = string.format("\nnamespace %s;\n\nusing Microsoft.Sales.Customer;\n", ns)
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

      vim.ui.select(
        vim.tbl_map(function(r) return r.label end, RUNTIMES),
        { prompt = "Target platform:" },
        function(choice)
          if not choice then return end
          local rv
          for _, r in ipairs(RUNTIMES) do
            if r.label == choice then rv = r; break end
          end
          if not rv then return end

          vim.ui.input({ prompt = "Publisher: ", default = "" }, function(publisher)
            if publisher == nil then return end  -- Esc = cancel; empty string is valid

            vim.ui.input({ prompt = "ID range start: ", default = "50100" }, function(id_str)
              if not id_str or id_str == "" then return end
              local id_from = tonumber(id_str)
              if not id_from or id_from < 0 then
                vim.notify("AL Go!: invalid ID range start", vim.log.levels.ERROR)
                return
              end

              -- The starter object goes straight to its CRS home. Writing it at
              -- the project root — which is what VSCode's template does — means
              -- wizard.organise_file renames it out from under the user on the
              -- very first :w, since it runs on BufWritePost for every AL file
              -- under the root. HELLO_WORLD_PATH must match wizard.build_path.
              local hw_path = proj_dir .. "/" .. HELLO_WORLD_PATH
              vim.fn.mkdir(proj_dir .. "/.alpackages", "p")
              vim.fn.mkdir(proj_dir .. "/.vscode",     "p")
              vim.fn.mkdir(vim.fn.fnamemodify(hw_path, ":h"), "p")

              local app_content = build_app_json(name, publisher, rv, id_from)
              local hw_content  = build_hello_world(name, publisher, rv, id_from)

              write_lines(proj_dir .. "/app.json",             app_content)
              write_lines(hw_path,                             hw_content)
              write_lines(proj_dir .. "/.vscode/launch.json",  LAUNCH_JSON)

              -- The ID cache is keyed per project+type and these writes fire no
              -- autocommands, so :ALNextId would not see the object just created.
              pcall(function() require("al.ids").invalidate() end)

              vim.schedule(function()
                vim.cmd("edit " .. vim.fn.fnameescape(hw_path))
                vim.notify(
                  string.format("AL Go!: project created → %s  (runtime %s)", proj_dir, rv.runtime),
                  vim.log.levels.INFO
                )
              end)
            end)
          end)
        end
      )
    end)
  end)
end

-- Internals reached by tests/project_spec.lua only — never call from plugin code.
M._test = {
  gen_uuid          = gen_uuid,
  build_app_json    = build_app_json,
  build_hello_world = build_hello_world,
  write_lines       = write_lines,
  HELLO_WORLD_PATH  = HELLO_WORLD_PATH,
  RUNTIMES          = RUNTIMES,
}

return M
