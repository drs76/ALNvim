-- Catnip build view is optional, and owns presentation rather than alc execution.
local T = require('tests.harness')
local describe, it, eq = T.describe, T.it, T.eq
local compile = require('al.compile')

describe('Catnip build output sink', function()
  it('streams, reopens, and edits only compiler diagnostic lines', function()
    local prior = package.loaded['catnip.ui']
    local set_keymap = vim.keymap.set
    local get_line = vim.api.nvim_get_current_line
    local calls, appended, edit_args = 0, {}, {}
    local key_callback, current_line
    local view = { buf = 12345, opens = 0 }
    function view:append(lines) vim.list_extend(appended, lines) end
    function view:open() self.opens = self.opens + 1 end
    function view:edit_file(opts) edit_args[#edit_args + 1] = opts end
    package.loaded['catnip.ui'] = {
      output = function(opts)
        calls = calls + 1
        eq('alnvim.build.output', opts.id)
        eq({}, opts.lines)
        return view
      end,
    }
    vim.keymap.set = function(mode, lhs, cb, opts)
      if mode == 'n' and lhs == '<CR>' then
        eq(12345, opts.buffer)
        key_callback = cb
      else
        return set_keymap(mode, lhs, cb, opts)
      end
    end
    vim.api.nvim_get_current_line = function() return current_line end
    local ok, err = xpcall(function()
      local buf, emit = compile._test.build_output_sink('AL Build', '/repo', '/repo', true)
      eq(12345, buf)
      emit({ '$ al compile', '', 'warning AA0137: unused' })
      eq({ '$ al compile', 'warning AA0137: unused' }, appended)
      eq(1, calls)
      eq(true, compile.open_catnip_build_output())
      eq(1, view.opens)
      assert(key_callback, 'No diagnostic Enter mapping installed')
      current_line = 'src/codeunit/Test.Codeunit.al(80,47): warning AA0137: unused'
      key_callback()
      eq({ file = '/repo/src/codeunit/Test.Codeunit.al', line = 80, col = 47 }, edit_args[1])
      current_line = 'C:\\proj\\Codeunit.al(12,3): error AL0118: unknown'
      key_callback()
      eq({ file = 'C:/proj/Codeunit.al', line = 12, col = 3 }, edit_args[2])
      current_line = '── Build succeeded  (1 warning(s)) ──'
      key_callback()
      eq(2, #edit_args)
    end, debug.traceback)
    vim.api.nvim_get_current_line = get_line
    vim.keymap.set = set_keymap
    package.loaded['catnip.ui'] = prior
    compile._catnip_build_view = nil
    if not ok then error(err) end
  end)
end)
