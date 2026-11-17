-- Pure conversion tests: the linked navigator is optional during ALNvim tests.
local T = require('tests.harness')
local describe, it, eq = T.describe, T.it, T.eq
local D = require('al.catnip_diagnostics')

describe('Catnip build diagnostics adapter', function()
  it('maps file-scoped errors and warnings with 1-based positions', function()
    local items, omitted = D.to_items({
      {filename='/repo/a.al', lnum=12, col=3, type='E', text='AL0118: unknown'},
      {filename='/repo/b.al', lnum=0, col=0, type='W', text='AA0137: unused'},
    })
    eq(0, omitted)
    eq({
      {file='/repo/a.al', line=12, col=3, severity='E', message='AL0118: unknown'},
      {file='/repo/b.al', line=1, col=1, severity='W', message='AA0137: unused'},
    }, items)
  end)

  it('keeps project-level diagnostics out of file navigation', function()
    local items, omitted = D.to_items({
      {type='E', text='AL1022: package not found'},
      {filename='C:/repo/a.al', lnum=3, col=4, type='W', text='AA0005: warning'},
    })
    eq(1, omitted)
    eq(1, #items)
    eq('C:/repo/a.al', items[1].file)
  end)

  it('handles zero diagnostics', function()
    local items, omitted = D.to_items({})
    eq({}, items)
    eq(0, omitted)
  end)
end)
