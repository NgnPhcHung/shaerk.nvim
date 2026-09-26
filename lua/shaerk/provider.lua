local M = {}

--- A provider is just data: a function that builds a command array.
--- The tmp path already lives in the query (contract.instructions); the tmp
--- parameter here is for a provider that needs its own output flag, and for the fake provider in tests.
M.claude = {
  name = "claude",
  --- @param query string
  --- @param _tmp string
  --- @return string[]
  cmd = function(query, _tmp)
    -- query goes before --allowedTools: it is variadic (<tools...>) and would
    -- otherwise swallow the prompt, leaving claude with no input under --print.
    return {
      "claude",
      "-p",
      query,
      "--allowedTools",
      "Read,Grep,Glob,Write",
    }
  end,
}

--- Latency- and cost-trimmed variant for suggestions. Measured: the CLI's own
--- session init dominates, so the win comes from dropping the exploration tools
--- and MCP startup, not from the smaller model.
--- --strict-mcp-config goes BEFORE --allowedTools for the same reason the query
--- does: --allowedTools is variadic and swallows everything after it.
M.fast = {
  name = "claude-fast",
  --- @param query string
  --- @param _tmp string
  --- @return string[]
  cmd = function(query, _tmp)
    return {
      "claude",
      "-p",
      query,
      "--model",
      "haiku",
      "--strict-mcp-config",
      "--allowedTools",
      "Write",
    }
  end,
}

M.default = M.claude

return M
