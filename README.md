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
- `tsconfig.json` `compilerOptions.paths` — explicit aliases, checked before
  the SFCC rules above (including mappings for `*/...` and `dw/...`)
- anything else falls back to the builtin `gf`

Omitted extensions are tried as `.js` / `.ds` / `.json` / `.ts` / `.d.ts`;
a directory resolves via `main.js` or `package.json` `"main"`.
`:checkhealth sfcc` shows what was detected.

## Setup

No keymaps are created — map the resolver yourself. A global mapping is
fine: outside a `dw.json` project or a matching `tsconfig.json` path alias,
it falls straight through to the builtin `gf`.

```lua
-- lazy.nvim: the plugin is loaded on the first gf press
{
  'ttak0422/sfcc.nvim',
  keys = {
    { 'gf', function() require('sfcc').gf() end, desc = 'SFCC cartridge gf' },
  },
}
```

Cartridge discovery and tsconfig settings are cached. Use `:SfccReset` after
adding cartridges or editing configs (including inherited configs).

## TypeScript path aliases

Aliases use the nearest ancestor `tsconfig.json` of the current script
(cwd for unnamed buffers), with JSONC and `extends` supported. Targets are
relative to `baseUrl` or the declaring config; the first existing target wins.
This is not full TypeScript module resolution: file probing follows the SFCC
rules above, and `baseUrl` alone does not resolve bare imports.

## Tests

```sh
nvim --headless -l tests/run.lua
```
