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

- `*/...` — resolved against the cartridge list from `dw.json`:
  `cartridgesPath` (or the `cartridge` array as fallback) is both the
  priority order and the whitelist, exactly like Prophet / Business
  Manager — the first match in declared order wins. Names are
  whitespace-trimmed. Without a usable list, every cartridge in the
  project (parents of `cartridge` directories) is searched and multiple
  hits are offered via `vim.ui.select`
- `~/...` — resolved within the cartridge containing the current file
- `<cartridge_name>/...` — a first segment naming a known cartridge resolves
  inside that cartridge. Gated on the project having a `dw.json`, so bare
  module paths (`lodash/fp`) never trigger a scan in ordinary JS projects
- `dw/...` — notifies that this is a server API module (no local file)
- anything else falls back to the builtin `gf`

The project root is the nearest ancestor of the current file containing
`dw.json` (falling back to the cwd); discovery is anchored there and cached
per project. Omitted extensions are tried as `.js` / `.ds` / `.json`.

## Setup

No keymaps are created for you — map the resolver yourself. A global
mapping is fine: unless the string under the cursor starts with `*/` or
`~/`, the resolver bails out to the builtin `gf` immediately without
touching the filesystem.

```lua
-- lazy.nvim: the plugin is loaded on the first gf press
{
  'ttak0422/sfcc.nvim',
  keys = {
    { 'gf', function() require('sfcc').gf() end, desc = 'SFCC cartridge gf' },
  },
}
```

If you'd rather scope it to JavaScript buffers only, map it in
`~/.config/nvim/after/ftplugin/javascript.lua` instead:

```lua
vim.keymap.set('n', 'gf', function()
  require('sfcc').gf()
end, { buffer = true, desc = 'SFCC cartridge gf' })
```

Cartridge discovery is cached per working directory; clear it with
`:SfccReset` (e.g. after adding a cartridge).

## Tests

```sh
nvim --headless -l tests/run.lua
```
