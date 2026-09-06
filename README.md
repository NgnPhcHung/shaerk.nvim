# shaerk.nvim

Generate code into **one region of one file**, using an agent CLI already on your machine.

The agent runs headless and is instructed (via the prompt and, for the default provider, a restricted tool list) to write its answer to a tmp file — this is a convention the agent follows, not a sandbox shaerk enforces. shaerk itself is the only thing that ever touches your buffer: it only ever reads the agent's answer back from that tmp file and splices it into the target region. shaerk never edits more than the one region it anchored, and never touches a file other than the buffer that region came from.

## Contribute 
Feel free to contribute

## Requirements

- Neovim >= 0.10
- `claude` CLI in `$PATH` (or your own provider, see below)

## Install

```lua
{
  "shaerk.nvim",
  config = function()
    local shaerk = require("shaerk")
    shaerk.setup({})

    -- Cursor inside a function or a comment block: spec comes from the buffer, no prompt
    vim.keymap.set("n", "<leader>ss", function() shaerk.run() end)

    -- Force a follow-up prompt for extra instructions
    vim.keymap.set("n", "<leader>sa", function() shaerk.run({ ask = true }) end)

    -- Visual selection
    vim.keymap.set("v", "<leader>ss", function()
      vim.cmd("normal! \27")
      shaerk.visual()
    end)

    vim.keymap.set("n", "<leader>sx", function() shaerk.cancel() end)
  end,
}
```

## Setup options

`shaerk.setup(opts)`:

| Name | Default | Meaning |
|---|---|---|
| `provider` | `require("shaerk.provider").claude` | A table `{ name, cmd(query, tmp) }`; `cmd` returns the command array to spawn |
| `tmp_dir` | `./.shaerk` | Where the agent writes its output file. Must be inside the CWD so the agent's sandbox is allowed to write there |

Add `.shaerk/` to your project's `.gitignore`.

`shaerk.run(opts)` takes `{ ask: boolean|nil }`. `shaerk.visual()` takes no options — it always prompts for input regardless of what's selected.

Only one request runs at a time, and that includes the follow-up prompt (`ask = true` / a free-form target): once a prompt is open, it counts as in flight even before the agent is spawned. Starting a second one while a request is in flight or a prompt is still open is refused with a notification; there is no queue.

## Three ways to trigger it

1. **Comment + function name.** Write a descriptive comment above an (empty) function, put the cursor in either, `<leader>ss`. The target region is the comment block plus the function.
2. **Function shell with step comments inside.** Write the function signature and describe each step as a comment in the body, cursor anywhere inside, `<leader>ss`. The whole function (plus any comment block directly above it) becomes the target, and the agent does every step in one pass.
3. **Open shaerk directly and type a free-form request.** Put the cursor on a blank/unrecognized spot, `<leader>ss` (or `<leader>sa`) — since there's no enclosing function or comment, shaerk prompts for input and inserts the result at the cursor.

Plus: select any arbitrary range in visual mode and `<leader>ss` — `shaerk.visual()` always prompts for extra input, using the selection's own text as context.

Target resolution (`lua/shaerk/target.lua`) walks the treesitter tree at the cursor: enclosing function node wins first, then an enclosing/sibling comment block, then falls back to an empty-range prompt at the cursor line.

## Provider contract

shaerk builds a single prompt containing: the whole buffer, the exact target lines, the user's spec, and a fixed `<Contract>` block (`lua/shaerk/contract.lua`) telling the agent to write its entire answer to the tmp file and nothing else, in this shape:

```
line 1: a single-line JSON header, e.g. {"v":1,"status":"ok","lang":"lua","note":"..."}
line 2: empty
line 3+: the body (raw code, replaces the whole target region — not a patch)
```

Header fields: `v` (must equal the contract version, currently `1`), `status` (`"ok"` | `"refused"` | `"no_change"`), `lang` (required when `status` is `"ok"`), `note` (required when `status` is `"refused"`, max 200 chars).

If the agent's output doesn't parse against this contract, shaerk retries once with the parse error appended to the prompt before giving up.

### Pointing at a different agent CLI

Pass your own provider table to `setup({ provider = ... })`:

```lua
{
  name = "my-agent",
  cmd = function(query, tmp)
    -- query already instructs the agent to write its answer to `tmp`;
    -- `tmp` itself is also passed in case your CLI needs an explicit
    -- output-file flag instead of parsing the path out of the prompt.
    return { "my-agent-cli", "--prompt", query }
  end,
}
```

The built-in default (`lua/shaerk/provider.lua`) runs `claude -p --allowedTools Read,Grep,Glob,Write <query>`.

## Terminal states

The buffer is only ever changed on `ok`. Every other state leaves the buffer untouched:

| State | Meaning |
|---|---|
| `ok` | Applied. |
| `refused` | The agent reports the request can't be done inside a single region. |
| `no_change` | The region was already correct. |
| `invalid_syntax` | Splicing the result into the buffer produces a parse error — shaerk opens a scratch buffer with the raw result instead of applying it. |
| `anchor_lost` | The target region was deleted, the buffer itself was closed, the region's text changed while the request was in flight, or — for a free-form insertion point with no region to speak of — the line above or at the insertion point changed underneath it. shaerk opens a scratch buffer with the result instead of guessing where it belongs. |
| `no_file` / `bad_header` | The agent didn't follow the contract, even after one retry. |
| `proc_failed` | The CLI process exited non-zero (or failed to spawn). |
| `cancelled` | `shaerk.cancel()` was called. |

## Limitations

- A result is refused (as `anchor_lost`) if the target region's text changed while the request was in flight — shaerk compares the region against the text it captured when the request started. This is deliberate: the agent's answer was computed against the old text, so applying it over changed text could be wrong or destructive. A free-form insertion point (no target region — `srow == erow`) has no range to diff, so shaerk instead compares a small context window captured at mark time: the line above and the line at the insertion point.
- The syntax gate is treesitter-based, so it fails open: a filetype with no installed parser gets no syntax check at all, and `invalid_syntax` can never fire for it.
- `shaerk.visual()` takes no options; only `shaerk.run()` accepts `{ ask }`.
- `tmp_dir` (default `./.shaerk`) is created relative to Neovim's current working directory, not relative to the target buffer's file. In a multi-project session, or if you `:cd` around, the tmp directory may not be where you expect it — pass an absolute path to `setup({ tmp_dir = ... })` if that matters to you.

## Test

```bash
make test
```

