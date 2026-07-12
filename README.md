# sfcc.nvim

Navigate Salesforce B2C Commerce Cloud (SFCC / Demandware) cartridge require
paths in Neovim — the path-resolution part of VSCode's
[Prophet Debugger](https://github.com/SqrTT/prophet).

```js
var util = require('*/cartridge/scripts/util');   // searched across all cartridges
var cart = require('~/cartridge/models/cart');    // resolved within the current cartridge
```

## Features

`require('sfcc').gf()` resolves the string under the cursor:

- `*/...` — searched across every cartridge in the workspace (parents of
  `cartridge` directories); multiple hits are offered via `vim.ui.select`
- `~/...` — resolved within the cartridge containing the current file
- `dw/...` — notifies that this is a server API module (no local file)
- anything else falls back to the builtin `gf`

Candidates are ordered by `cartridgesPath` (`:` or `,` separated) from
`dw.json` at the workspace root, when present. Omitted extensions are tried
as `.js` / `.ds` / `.json`.

## Setup

No keymaps are created for you — map the resolver yourself, buffer-locally
so it only runs in JavaScript buffers:

```lua
-- lazy.nvim
{
  'ttak0422/sfcc.nvim',
  ft = 'javascript',
  config = function()
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'javascript',
      callback = function(ev)
        vim.keymap.set('n', 'gf', function()
          require('sfcc').gf()
        end, { buffer = ev.buf, desc = 'SFCC cartridge gf' })
      end,
    })
  end,
}
```

or equivalently in `~/.config/nvim/after/ftplugin/javascript.lua`:

```lua
vim.keymap.set('n', 'gf', function()
  require('sfcc').gf()
end, { buffer = true, desc = 'SFCC cartridge gf' })
```

Unresolved paths fall back to the builtin `gf`, so the mapping is safe in
plain (non-SFCC) JavaScript projects too.

Cartridge discovery is cached per working directory; clear it with
`:SfccReset` (e.g. after adding a cartridge).

## Tests

```sh
nvim --headless -l tests/run.lua
```
