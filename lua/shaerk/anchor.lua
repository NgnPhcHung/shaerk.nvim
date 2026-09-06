local ns = vim.api.nvim_create_namespace("shaerk")

--- @class shaerk.Anchor
--- @field buf number
--- @field id number
--- @field empty boolean
--- @field above string|nil line above an empty anchor's insertion point, captured at mark time
--- @field at string|nil line at an empty anchor's insertion point, captured at mark time
local Anchor = {}
Anchor.__index = Anchor

local M = {}

--- Anchor a line range with exactly one ranged extmark.
--- right_gravity=false + end_right_gravity=true so the range expands when the user types inside it,
--- instead of shrinking and losing the marker.
--- @param buf number
--- @param srow number 0-indexed
--- @param erow number 0-indexed, exclusive
--- @return shaerk.Anchor
function M.mark(buf, srow, erow)
  local empty = erow <= srow
  local opts = { right_gravity = false }
  local above, at = nil, nil

  if not empty then
    local last = erow - 1
    local text = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
    opts.end_row = last
    opts.end_col = #text
    opts.end_right_gravity = true
  else
    -- A zero-width mark can't be distinguished from a deleted one (see
    -- valid()), so it has no range to diff against on mid-flight change. Capture
    -- a small context window instead — the line above and the line at the
    -- insertion point — so a whole-buffer replace mid-flight is still caught.
    local line_count = vim.api.nvim_buf_line_count(buf)
    above = srow > 0 and vim.api.nvim_buf_get_lines(buf, srow - 1, srow, false)[1] or nil
    at = srow < line_count and vim.api.nvim_buf_get_lines(buf, srow, srow + 1, false)[1] or nil
  end

  local id = vim.api.nvim_buf_set_extmark(buf, ns, srow, 0, opts)
  return setmetatable({ buf = buf, id = id, empty = empty, above = above, at = at }, Anchor)
end

--- @return table|nil pos { row, col, details }
function Anchor:_get()
  local pos = vim.api.nvim_buf_get_extmark_by_id(self.buf, ns, self.id, { details = true })
  if not pos or #pos == 0 then
    return nil
  end
  return pos
end

--- @return number srow 0-indexed
--- @return number erow 0-indexed, exclusive
function Anchor:range()
  local pos = self:_get()
  if not pos then
    return 0, 0
  end
  local srow = pos[1]
  if self.empty then
    return srow, srow
  end
  return srow, (pos[3].end_row or srow) + 1
end

--- @return boolean
function Anchor:valid()
  local pos = self:_get()
  if not pos then
    return false
  end
  if self.empty then
    return true
  end
  local details = pos[3]
  if details.end_row == nil then
    return false
  end
  -- If the range was deleted entirely, the extmark collapses to zero-width.
  if details.end_row == pos[1] and details.end_col <= pos[2] then
    return false
  end
  return true
end

--- Replace the range with exactly one set_lines call so it creates only one undo entry.
--- @param lines string[]
function Anchor:apply(lines)
  local srow, erow = self:range()
  -- Close the current undo block (:h undo-blocks) so the set_lines below
  -- always creates its OWN undo entry, not merged with the preceding change.
  vim.bo[self.buf].undolevels = vim.bo[self.buf].undolevels
  vim.api.nvim_buf_set_lines(self.buf, srow, erow, false, lines)
  self:clear()
end

function Anchor:clear()
  pcall(vim.api.nvim_buf_del_extmark, self.buf, ns, self.id)
end

--- For an empty anchor only: has the context window captured at mark time
--- (the line above and the line at the insertion point) changed?
--- @return boolean
function Anchor:context_changed()
  local srow = self:range()
  local line_count = vim.api.nvim_buf_line_count(self.buf)
  local above = srow > 0 and vim.api.nvim_buf_get_lines(self.buf, srow - 1, srow, false)[1] or nil
  local at = srow < line_count and vim.api.nvim_buf_get_lines(self.buf, srow, srow + 1, false)[1]
    or nil
  return above ~= self.above or at ~= self.at
end

return M
