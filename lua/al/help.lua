-- AL Help: open MS Learn AL documentation in the default browser.
--
-- M.open([url])  – :ALHelp [url/slug]   open a page (default: AL overview)
-- M.topics()     – :ALHelpTopics        pick a topic from the curated list

local M = {}

local LEARN_PREFIX =
  "https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/"

-- Curated topic list  { display label, slug }
local TOPICS = {
  -- ── Language fundamentals ──────────────────────────────────────────────────
  { "Programming in AL",                  "devenv-programming-in-al" },
  { "AL Code Guidelines",                 "devenv-al-code-guidelines" },
  { "Variables and Constants",            "devenv-variables-and-constants" },
  { "Data Types Overview",                "devenv-data-types-overview" },
  { "Simple Statements",                  "devenv-al-simple-statements" },
  { "Compound Statements",                "devenv-al-compound-statements" },
  { "Procedures and Triggers",            "devenv-al-procedures-and-triggers" },
  { "Error Handling",                     "devenv-al-error-handling" },
  -- ── Objects ────────────────────────────────────────────────────────────────
  { "Table Object",                       "devenv-table-object" },
  { "Table Extension Object",             "devenv-table-extension-object" },
  { "Page Object",                        "devenv-page-object" },
  { "Page Extension Object",              "devenv-page-extension-object" },
  { "Page Customization Object",          "devenv-page-customization-object" },
  { "Codeunit Object",                    "devenv-codeunit-object" },
  { "Report Object",                      "devenv-report-object" },
  { "Report Extension Object",            "devenv-report-extension-object" },
  { "Query Object",                       "devenv-query-object" },
  { "XmlPort Object",                     "devenv-xmlport-object" },
  { "Enum Object",                        "devenv-enum-object" },
  { "Enum Extension Object",              "devenv-enum-extension-object" },
  { "Interface Object",                   "devenv-interface-object" },
  { "Permission Set Object",              "devenv-permissionset-object" },
  -- ── Events ─────────────────────────────────────────────────────────────────
  { "Events in AL",                       "devenv-events-in-al" },
  { "Publishing Events",                  "devenv-event-types" },
  { "Subscribing to Events",              "devenv-subscribing-to-events" },
  { "Raising Events",                     "devenv-raising-events" },
  -- ── Pages and UI ───────────────────────────────────────────────────────────
  { "Pages Overview",                     "devenv-pages-overview" },
  { "Page Types and Layouts",             "devenv-page-types-and-layouts" },
  { "Actions Overview",                   "devenv-actions-overview" },
  { "FlowFields",                         "devenv-flowfields" },
  -- ── API / Integration ──────────────────────────────────────────────────────
  { "API Pages",                          "devenv-api-pages" },
  { "Web Services Overview",              "devenv-web-services" },
  -- ── Testing ────────────────────────────────────────────────────────────────
  { "Testing AL Code",                    "devenv-testing-application" },
  { "Test Codeunits and Methods",         "devenv-test-codeunits-and-test-methods" },
}

-- Extract a slug from a bare slug, a relative .md filename, or a full MS Learn URL.
local function to_slug(input)
  if not input or input == "" then return nil end
  local from_url = input:match(LEARN_PREFIX:gsub("%-", "%%-") .. "([%w%-]+)")
  if from_url then return from_url end
  local from_md = input:match("^([%w%-]+)%.md$")
  if from_md then return from_md end
  if input:match("^devenv%-") then return input end
  return nil
end

-- Open a slug or full URL in the default browser.
function M.open(input)
  local url
  if input and input:match("^https?://") then
    url = input
  else
    local slug = to_slug(input) or TOPICS[1][2]
    url = LEARN_PREFIX .. slug
  end
  require("al.platform").open_url(url)
end

function M.topics()
  local labels = {}
  for _, t in ipairs(TOPICS) do
    labels[#labels + 1] = t[1]
  end
  vim.ui.select(labels, { prompt = "AL Help — select topic:" }, function(choice)
    if not choice then return end
    for _, t in ipairs(TOPICS) do
      if t[1] == choice then
        require("al.platform").open_url(LEARN_PREFIX .. t[2])
        return
      end
    end
  end)
end

-- Kept for backwards compat (plugin/al.lua calls M.toggle).
M.toggle = M.open

return M
