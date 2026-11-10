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

Cartridge discovery and loaded tsconfig settings are cached; clear them with
`:SfccReset` after adding a cartridge or editing a config (including an
extended config).

## TypeScript path aliases

The nearest ancestor `tsconfig.json` of the current script is used, or the
working directory's nearest config when no file is named. There is no recursive
config search. This also works without `dw.json` and in JavaScript/SFCC scripts.

```jsonc
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@app/*": ["cartridges/app_custom/cartridge/*"],
      "server": ["modules/server"],
    },
  },
}
```

- Comments, trailing commas and a UTF-8 BOM are accepted.
- Targets are relative to `baseUrl`, if set, otherwise to the config that
  declares `paths`. Relative `baseUrl` is anchored to its declaring config.
  Windows-style separators are accepted. A leading `${configDir}` in `baseUrl`
  or a target refers to the final consuming config's directory.
- Exact aliases win over wildcard patterns. Patterns allow one `*`; the
  longest prefix before `*` wins (ties use declaration order). Only that
  pattern's targets are tried, in array order, stopping at the first file.
- `extends` accepts relative/absolute config files, optional `.json`, arrays
  (later entries win), and packages in ancestor `node_modules` directories
  (config subpaths, `package.json` `tsconfig`, or `tsconfig.json`). A child's
  `paths` replaces the inherited map rather than merging individual aliases.
- An unresolved mapping falls back to the existing SFCC rules. Relative
  imports and `module.superModule` keep their existing behavior. Non-script
  buffers keep their filetype's builtin `gf` behavior.

This is path mapping, not the full TypeScript module resolver: file extensions
and directory entry points follow the SFCC rules above. `baseUrl` alone does
not enable bare imports; `jsconfig.json`, project references, package exports,
Yarn PnP, and TypeScript-specific extension substitution are not implemented.
`:checkhealth sfcc` shows the selected config and config-loading problems.

## Tests

```sh
nvim --headless -l tests/run.lua
```
