-- Optional adapter: AL compiler quickfix entries -> Catnip linked navigator.
-- No compiler, quickfix, dashboard, or window-lifecycle changes here.
local M = {}

function M.to_items(qf)
  local items, project_level = {}, 0
  for _, diagnostic in ipairs(qf or {}) do
    if type(diagnostic.filename) == 'string' and diagnostic.filename ~= '' then
      items[#items + 1] = {
        file = diagnostic.filename,
        line = math.max(1, tonumber(diagnostic.lnum) or 1),
        col = math.max(1, tonumber(diagnostic.col) or 1),
        severity = diagnostic.type == 'E' and 'E' or diagnostic.type == 'W' and 'W' or 'I',
        message = diagnostic.text or '',
      }
    else
      project_level = project_level + 1
    end
  end
  return items, project_level
end

function M.open(qf)
  local items, project_level = M.to_items(qf)
  if #items == 0 then
    vim.notify(project_level > 0
      and 'AL: Only project-level diagnostics; inspect :copen or the build output'
      or 'AL: No file diagnostics in the last build', vim.log.levels.INFO)
    return false
  end

  local ok, navigator = pcall(require, 'catnip.navigator')
  if not ok or type(navigator.navigator) ~= 'function' then
    vim.notify('AL: Catnip navigator is unavailable (legacy build panel remains available)',
      vim.log.levels.WARN)
    return false
  end
  if project_level > 0 then
    vim.notify(('AL: %d project-level diagnostic(s) remain in quickfix'):format(project_level),
      vim.log.levels.INFO)
  end
  navigator.navigator({
    id = 'alnvim.build.diagnostics',
    title = '🐜 AL Build Diagnostics',
    items = items,
  })
  return true
end

return M
