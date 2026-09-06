local M = {}

M.VERSION = 1
M.NOTE_MAX = 200

local VALID_STATUS = { ok = true, refused = true, no_change = true }

--- Deliberately asymmetric with M.parse: the instructions state exactly one
--- strict shape (telling the agent fences are accepted would make it use
--- fences more), while parse is lenient so it doesn't discard a correct answer over a format slip.
--- The format instructions sent to the agent. This is the "write" half of the contract;
--- M.parse is the "read" half. Changing one side requires changing the other.
--- @param tmp string
--- @return string
function M.instructions(tmp)
  return table.concat({
    "<Contract>",
    "Write your entire answer to this file and nothing else: " .. tmp,
    "Do not create or modify any other file. Do not print the answer to stdout.",
    "",
    "The file must have exactly this shape:",
    "  line 1: a single-line JSON object (the header)",
    "  line 2: empty",
    "  line 3+: the body",
    "",
    "Header fields:",
    "  v      (number, required) must be " .. M.VERSION,
    '  status (string, required) one of "ok", "refused", "no_change"',
    '  lang   (string, required when status is "ok") language of the body, e.g. "lua"',
    '  note   (string, required when status is "refused") one line, max '
      .. M.NOTE_MAX
      .. " chars",
    "",
    "Body rules:",
    '  - Present only when status is "ok".',
    "  - Raw code only. No markdown fences, no explanation, no leading blank line.",
    "  - Absolute indentation exactly as it must appear in the file.",
    "  - It replaces the whole target region. It is not a patch.",
    "",
    '  Use "refused" when the request cannot be satisfied inside the target region alone.',
    '  Use "no_change" when the region is already correct.',
    "",
    "Example:",
    string.format(
      '{"v":%d,"status":"ok","lang":"lua","note":"guarded with pcall"}',
      M.VERSION
    ),
    "",
    "local function read_config(path)",
    "  return nil",
    "end",
    "</Contract>",
  }, "\n")
end

--- @param lines string[]
--- @return string[]
local function strip_cr(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = (line:gsub("\r$", ""))
  end
  return out
end

--- Strip a ```fence wrapping the body in case the agent added one by mistake.
--- @param lines string[]
--- @return string[]
local function strip_fence(lines)
  if #lines >= 2 and lines[1]:match("^%s*```") and lines[#lines]:match("^%s*```%s*$") then
    return vim.list_slice(lines, 2, #lines - 1)
  end
  return lines
end

--- @param lines string[]
--- @return string[]
local function trim_trailing_blanks(lines)
  local last = #lines
  while last > 0 and lines[last]:match("^%s*$") do
    last = last - 1
  end
  return vim.list_slice(lines, 1, last)
end

--- @class shaerk.Result
--- @field status "ok"|"refused"|"no_change"
--- @field lang string|nil
--- @field note string|nil
--- @field body string|nil

--- @param path string
--- @return shaerk.Result|nil
--- @return "no_file"|"bad_header"|nil
function M.parse(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "no_file"
  end

  local ok_read, raw = pcall(vim.fn.readfile, path)
  if not ok_read or type(raw) ~= "table" or #raw == 0 then
    return nil, "no_file"
  end

  local lines = strip_cr(raw)

  local ok_json, header = pcall(vim.json.decode, lines[1])
  if not ok_json or type(header) ~= "table" then
    return nil, "bad_header"
  end
  if header.v ~= M.VERSION then
    return nil, "bad_header"
  end
  if type(header.status) ~= "string" or not VALID_STATUS[header.status] then
    return nil, "bad_header"
  end
  if header.status == "ok" and type(header.lang) ~= "string" then
    return nil, "bad_header"
  end
  if header.status == "refused" and type(header.note) ~= "string" then
    return nil, "bad_header"
  end

  local note = nil
  if type(header.note) == "string" then
    note = header.note:sub(1, M.NOTE_MAX)
  end

  local body = nil
  if header.status == "ok" then
    local first = (lines[2] ~= nil and lines[2]:match("^%s*$")) and 3 or 2
    local body_lines = trim_trailing_blanks(strip_fence(vim.list_slice(lines, first)))
    if #body_lines == 0 then
      return nil, "bad_header"
    end
    body = table.concat(body_lines, "\n")
    if vim.trim(body) == "" then
      return nil, "bad_header"
    end
  end

  return { status = header.status, lang = header.lang, note = note, body = body }, nil
end

--- Splice the body into the target region and parse the whole buffer.
--- The body may be a fragment that can't stand on its own, so parsing it in isolation would report a false error.
--- @param buf number
--- @param srow number 0-indexed
--- @param erow number 0-indexed, exclusive
--- @param body string
--- @return boolean ok
function M.check_syntax(buf, srow, erow, body)
  local ft = vim.bo[buf].filetype
  local lang = vim.treesitter.language.get_lang(ft)
  if not lang then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local head = vim.list_slice(lines, 1, srow)
  local tail = vim.list_slice(lines, erow + 1)
  local merged = vim.list_extend(head, vim.split(body, "\n"))
  merged = vim.list_extend(merged, tail)

  local ok, parser =
    pcall(vim.treesitter.get_string_parser, table.concat(merged, "\n"), lang)
  if not ok or not parser then
    return true
  end

  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return true
  end
  return not trees[1]:root():has_error()
end

return M
