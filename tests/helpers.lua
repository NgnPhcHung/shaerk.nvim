local M = {}

local counter = 0

--- Create a unique tmp file path in the system's temp directory.
--- @return string
function M.tmpfile()
  counter = counter + 1
  return string.format("%s/shaerk-test-%d-%d.out", vim.fn.tempname(), vim.uv.os_getpid(), counter)
end

--- @param path string
--- @param text string
function M.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(text)
  fd:close()
end

--- Create a scratch buffer with the given content and filetype.
--- @param lines string[]
--- @param filetype string|nil
--- @return number buf
function M.buf(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

return M
