local contract = require("shaerk.contract")

local MAX_RETRIES = 1

--- @class shaerk.Request
--- @field tmp string
--- @field prov table
--- @field build fun(format_err: string|nil): string
--- @field on_done fun(state: string, res: shaerk.Result|nil, detail: string|nil)
--- @field cancelled boolean
--- @field done boolean
--- @field proc table|nil
local Request = {}
Request.__index = Request

local M = {}

--- @param o table
--- @return shaerk.Request
function M.start(o)
  local self = setmetatable({
    tmp = o.tmp,
    prov = o.prov,
    build = o.build,
    on_done = o.on_done,
    cancelled = false,
    done = false,
    proc = nil,
  }, Request)
  self:_attempt(nil, MAX_RETRIES)
  return self
end

--- @param state string
--- @param res shaerk.Result|nil
--- @param detail string|nil
function Request:_finish(state, res, detail)
  if self.done then
    return
  end
  self.done = true
  os.remove(self.tmp)
  self.on_done(state, res, detail)
end

function Request:cancel()
  if self.done then
    return
  end
  self.cancelled = true
  if self.proc then
    pcall(function()
      self.proc:kill(15)
    end)
  end
  self:_finish("cancelled")
end

--- @param stderr string|nil
--- @return string
local function stderr_tail(stderr)
  local lines = vim.split(stderr or "", "\n", { trimempty = true })
  local from = math.max(1, #lines - 2)
  return table.concat(vim.list_slice(lines, from), "\n")
end

--- @param format_err string|nil
--- @param retries_left number
function Request:_attempt(format_err, retries_left)
  if self.cancelled then
    return
  end

  os.remove(self.tmp)

  -- self.build can throw (e.g. it reads anchor:range() on a buffer that was
  -- closed while a previous attempt was in flight) and so can self.prov.cmd —
  -- pcall the whole synchronous setup, on the first attempt AND every retry,
  -- and route a failure to proc_failed instead of letting it escape from
  -- inside the scheduled callback and wedge the plugin forever.
  local ok, proc_or_err = pcall(function()
    local query = self.build(format_err)
    local cmd = self.prov.cmd(query, self.tmp)

    -- vim.system reports a spawn error (e.g. ENOENT) synchronously via error(),
    -- not through the exit callback — caught by this same pcall instead of
    -- crashing out of request.start().
    return vim.system(cmd, { text = true }, vim.schedule_wrap(function(obj)
      if self.cancelled then
        return
      end

      if obj.code ~= 0 then
        return self:_finish("proc_failed", nil, stderr_tail(obj.stderr))
      end

      local res, err = contract.parse(self.tmp)
      if err then
        if retries_left > 0 then
          return self:_attempt(err, retries_left - 1)
        end
        return self:_finish(err)
      end

      return self:_finish("parsed", res)
    end))
  end)

  if not ok then
    return self:_finish("proc_failed", nil, tostring(proc_or_err))
  end
  self.proc = proc_or_err
end

return M
