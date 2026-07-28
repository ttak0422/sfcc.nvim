# sfcc.nvim

Navigate Salesforce B2C Commerce Cloud (SFCC / Demandware) cartridge require
paths in Neovim — the path-resolution part of VSCode's
[Prophet Debugger](https://github.com/SqrTT/prophet).

```js
var util = require('*/cartridge/scripts/util');   // searched across all cartridges
var cart = require('~/cartridge/models/cart');    // resolved within the current cartridge
var server = require('server');                   // the workspace modules/ folder
```

## Features

`require('sfcc').gf()` resolves the string under the cursor. Cartridges are
discovered from the workspace and ordered by `cartridgesPath` in `dw.json` —
the first match in declared order wins:

- `*/...` — searched across the cartridge path
- `~/...` — the cartridge containing the current file
- `./...` / `../...` — relative to the buffer's directory
- `<cartridge_name>/...` — inside that cartridge
- bare paths (`server`) — the workspace `modules` folder
- `dw/...` — server API module, no local file
- cursor on `module.superModule` — the same file in the next cartridge down
  the order
- anything else falls back to the builtin `gf`

Omitted extensions are tried as `.js` / `.ds` / `.json` / `.ts` / `.d.ts`;
a directory resolves via `main.js` or `package.json` `"main"`.
`:checkhealth sfcc` shows what was detected.

## Setup

No keymaps are created — map the resolver yourself. A global mapping is
fine: outside a `dw.json` project it falls straight through to the
builtin `gf`.

```lua
-- lazy.nvim: the plugin is loaded on the first gf press
{
  'ttak0422/sfcc.nvim',
  keys = {
    { 'gf', function() require('sfcc').gf() end, desc = 'SFCC cartridge gf' },
  },
}
```

Cartridge discovery is cached per working directory; clear it with
`:SfccReset` (e.g. after adding a cartridge).

## Tests

```sh
nvim --headless -l tests/run.lua
```
