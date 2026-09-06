local M = {}

--- Languages whose node names don't contain "function" or "method".
--- Elixir defines functions with a "call" node (def/defp is a macro call).
M.FN_OVERRIDE = {
  elixir = { call = true },
}

--- @param node TSNode
--- @param ft string
--- @return boolean
local function is_fn(node, ft)
  local t = node:type()
  if t:match("function") or t:match("method") then
    return true
  end
  local override = M.FN_OVERRIDE[ft]
  return override ~= nil and override[t] == true
end

--- @return TSNode|nil
local function node_at_cursor()
  -- get_node() only reads an already-parsed tree, it does not parse itself;
  -- outside a real buffer (with a FileType autocmd turning on highlighting)
  -- the tree may not exist yet, so we must parse explicitly before asking node.
  -- get_parser returns nil (does not throw) when the filetype has no parser
  -- installed, so we must check `parser` too, not just `ok`.
  local ok, parser = pcall(vim.treesitter.get_parser)
  if not ok or not parser then
    return nil
  end
  if not pcall(parser.parse, parser) then
    return nil
  end

  local ok2, node = pcall(vim.treesitter.get_node)
  if not ok2 then
    return nil
  end
  return node
end

--- @param node TSNode
--- @param ft string
--- @return TSNode|nil
local function enclosing_fn(node, ft)
  while node do
    if is_fn(node, ft) then
      return node
    end
    node = node:parent()
  end
  return nil
end

--- Walk back through adjacent sibling comments, with no blank line between them.
--- @param node TSNode
--- @return number srow 0-indexed
local function extend_up_comments(node)
  local srow = node:start()
  local prev = node:prev_sibling()
  while prev and prev:type():match("comment") do
    local prev_srow, _, prev_erow, _ = prev:range()
    if prev_erow + 1 < srow then
      break
    end
    srow = prev_srow
    prev = prev:prev_sibling()
  end
  return srow
end

--- The contiguous comment block around a comment node.
--- @param node TSNode
--- @return number srow, number erow_exclusive
local function comment_block(node)
  local srow = extend_up_comments(node)
  local _, _, erow, _ = node:range()

  local nxt = node:next_sibling()
  while nxt and nxt:type():match("comment") do
    local nxt_srow, _, nxt_erow, _ = nxt:range()
    if nxt_srow > erow + 1 then
      break
    end
    erow = nxt_erow
    nxt = nxt:next_sibling()
  end

  return srow, erow + 1
end

--- @param buf number
--- @param srow number
--- @param erow number
--- @return string
local function text_of(buf, srow, erow)
  return table.concat(vim.api.nvim_buf_get_lines(buf, srow, erow, false), "\n")
end

--- @class shaerk.Target
--- @field buf number
--- @field srow number 0-indexed
--- @field erow number 0-indexed, exclusive
--- @field spec string
--- @field needs_input boolean

--- @param opts { visual: boolean|nil }
--- @return shaerk.Target
function M.resolve(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype

  if opts.visual then
    local s = vim.api.nvim_buf_get_mark(buf, "<")[1] - 1
    local e = vim.api.nvim_buf_get_mark(buf, ">")[1]
    return {
      buf = buf,
      srow = s,
      erow = e,
      spec = text_of(buf, s, e),
      needs_input = true,
    }
  end

  local node = node_at_cursor()
  if node then
    local fn = enclosing_fn(node, ft)
    if fn then
      local srow = extend_up_comments(fn)
      local _, _, erow, _ = fn:range()
      return {
        buf = buf,
        srow = srow,
        erow = erow + 1,
        spec = text_of(buf, srow, erow + 1),
        needs_input = false,
      }
    end

    if node:type():match("comment") then
      local srow, erow = comment_block(node)
      return {
        buf = buf,
        srow = srow,
        erow = erow,
        spec = text_of(buf, srow, erow),
        needs_input = false,
      }
    end
  end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return { buf = buf, srow = row, erow = row, spec = "", needs_input = true }
end

return M
