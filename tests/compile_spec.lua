-- compile.lua — job output framing and diagnostic parsing.

local T = require("tests.harness")
local describe, it, eq = T.describe, T.it, T.eq
local C = require("al.compile")._test

-- Collect every line the stream emits for a sequence of jobstart chunks.
local function drain(chunks)
  local got = {}
  local feed, flush = C.line_stream(function(lines)
    for _, l in ipairs(lines) do got[#got + 1] = l end
  end)
  for _, c in ipairs(chunks) do feed(c) end
  flush()
  return got
end

describe("compile.line_stream", function()
  it("joins a line split across chunks", function()
    -- jobstart gives data[1] continuing the previous partial line and
    -- data[#data] itself partial. Appending chunks verbatim used to split a
    -- diagnostic in two, so it never matched the quickfix pattern.
    eq({ "/p/f.al(12,5): error AL0118: unknown identifier" },
       drain({ { "/p/f.al(12,5): error AL0" }, { "118: unknown identifier", "" } }))
  end)

  it("handles a line split across three chunks", function()
    eq({ "abcdef" }, drain({ { "ab" }, { "cd" }, { "ef" } }))
  end)

  it("carries a remainder across chunks that add no newline", function()
    -- "thr" is partial; the next two chunks contain no line break, so it stays
    -- in the carry and only flush() releases the completed "three".
    eq({ "one", "two", "three" }, drain({ { "one", "two", "thr" }, { "" }, { "ee" } }))
  end)

  it("flush emits a trailing line with no newline", function()
    eq({ "no trailing newline" }, drain({ { "no trailing newline" } }))
  end)

  it("emits nothing for empty output", function()
    eq({}, drain({ { "" } }))
  end)

  it("preserves blank lines between content", function()
    eq({ "a", "", "b" }, drain({ { "a", "", "b", "" } }))
  end)
end)

describe("compile.parse_output", function()
  it("parses a file-scoped diagnostic", function()
    eq({ { filename = "/p/f.al", lnum = 12, col = 5, type = "E",
           text = "AL0118: unknown identifier" } },
       C.parse_output({ "/p/f.al(12,5): error AL0118: unknown identifier" }))
  end)

  it("maps warning to type W", function()
    local qf = C.parse_output({ "/p/f.al(1,1): warning AA0005: begin/end" })
    eq("W", qf[1].type)
  end)

  it("resolves a relative path against the build cwd", function()
    -- alc inherits Neovim's cwd, which need not be the project dir.
    local qf = C.parse_output({ "src/f.al(3,4): error AL0118: x" }, "/build/cwd")
    eq("/build/cwd/src/f.al", qf[1].filename)
  end)

  it("leaves an absolute path alone", function()
    local qf = C.parse_output({ "/abs/f.al(3,4): error AL0118: x" }, "/build/cwd")
    eq("/abs/f.al", qf[1].filename)
  end)

  it("normalises Windows separators", function()
    local qf = C.parse_output({ [[C:\p\f.al(3,4): error AL0118: x]] }, "/cwd")
    eq("C:/p/f.al", qf[1].filename)
  end)

  it("parses a project-level diagnostic with no file", function()
    local qf = C.parse_output({ "error AL1022: package not found" })
    eq(1, #qf)
    eq(nil, qf[1].filename)
    eq("AL1022: package not found", qf[1].text)
  end)

  it("ignores lines that are not diagnostics", function()
    eq({}, C.parse_output({ "Microsoft (R) AL Compiler", "", "Build succeeded." }))
  end)
end)
