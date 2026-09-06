local ns = vim.api.nvim_create_namespace("shaerk.ui")

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INTERVAL = 100

local M = {}

--- @class shaerk.Spinner
--- @field timer table|nil
--- @field buf number
--- @field id number|nil
local Spinner = {}
Spinner.__index = Spinner

--- @param anchor shaerk.Anchor
--- @return shaerk.Spinner
function M.spinner(anchor)
  local self = setmetatable({ buf = anchor.buf, timer = nil, id = nil }, Spinner)
  local frame = 1

  local function draw()
    if not vim.api.nvim_buf_is_valid(self.buf) then
      self:stop()
      return
    end
    local srow = anchor:range()
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, srow, 0, {
      id = self.id,
      virt_text = { { " " .. FRAMES[frame] .. " shaerk", "Comment" } },
      virt_text_pos = "eol",
    })
    if ok then
      self.id = id
    end
    frame = frame % #FRAMES + 1
  end

  draw()
  self.timer = vim.uv.new_timer()
  self.timer:start(INTERVAL, INTERVAL, vim.schedule_wrap(draw))
  return self
end

function Spinner:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, self.buf, ns, 0, -1)
  end
  self.id = nil
end

local LEVELS = {
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

--- @param msg string
--- @param level "info"|"warn"|"error"|nil
function M.notify(msg, level)
  vim.notify("shaerk: " .. msg, LEVELS[level or "info"])
end

--- Open a scratch buffer so the user can see a result that could not be applied.
--- @param lines string[]
--- @param filetype string
--- @param title string
--- @return number buf
function M.preview(lines, filetype, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype
  pcall(vim.api.nvim_buf_set_name, buf, title)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

--- ponytail: vim.ui.input is one line. If the freeform requirement outgrows it,
--- upgrade to a scratch prompt buffer — without changing the call site.
--- @param prompt string
--- @param cb fun(input: string|nil)
function M.ask(prompt, cb)
  vim.ui.input({ prompt = prompt }, cb)
end

return M
