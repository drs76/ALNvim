-- Test entry point. Invoked by tests/run.sh:
--   nvim --headless -u NONE --cmd "set rtp+=<repo>" -l tests/run.lua

local T = require("tests.harness")

-- Expose the assertion vocabulary to the spec files.
_G.describe, _G.it, _G.eq, _G.ok, _G.errors = T.describe, T.it, T.eq, T.ok, T.errors

local specs = vim.fn.glob(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
                          .. "/*_spec.lua", false, true)
table.sort(specs)

for _, path in ipairs(specs) do
  io.stderr:write("── " .. vim.fn.fnamemodify(path, ":t:r") .. "\n")
  local chunk, load_err = loadfile(path)
  if not chunk then
    T.failed = T.failed + 1
    table.insert(T.failures, path .. "\n      " .. tostring(load_err))
  else
    local ran, run_err = pcall(chunk)
    if not ran then
      T.failed = T.failed + 1
      table.insert(T.failures, path .. "\n      " .. tostring(run_err))
    end
  end
end

os.exit(T.report() and 0 or 1)
