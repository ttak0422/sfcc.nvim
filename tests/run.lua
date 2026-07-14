-- nvim --headless -l tests/run.lua
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local root = vim.fn.tempname()
local function touch(rel)
  local path = root .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({}, path)
end

touch('cartridges/app_custom/cartridge/scripts/util.js')
touch('node_modules/pkg/cartridge/scripts/util.js') -- must never be treated as a cartridge
touch('cartridges/app_storefront_base/cartridge/scripts/util.js')
touch('cartridges/app_storefront_base/cartridge/config/prefs.json')
vim.fn.writefile({ '{"hostname":"x","cartridgesPath":"app_custom:app_storefront_base"}' }, root .. '/dw.json')
vim.fn.chdir(root)

vim.opt.runtimepath:prepend(plugin_root)
local sfcc = require('sfcc')

-- '*' searches every cartridge, ordered by dw.json cartridgesPath
local found, ordered = sfcc.resolve('*/cartridge/scripts/util', '')
assert(#found == 2, 'expected 2 hits, got ' .. #found)
assert(found[1]:find('app_custom', 1, true), 'dw.json order not applied: ' .. found[1])
assert(ordered, 'dw.json cartridgesPath must mark the result as ordered')

-- project root is located from the file via dw.json, independent of cwd
sfcc.reset()
vim.fn.chdir(root .. '/cartridges')
found, ordered = sfcc.resolve('*/cartridge/scripts/util', root .. '/cartridges/app_custom/cartridge/scripts/util.js')
assert(#found == 2 and ordered, 'resolution must not depend on cwd')
vim.fn.chdir(root)

-- extensionless .json resolution
found = sfcc.resolve('*/cartridge/config/prefs.json', '')
assert(#found == 1)

-- '~' resolves inside the current cartridge only
local buf = root .. '/cartridges/app_storefront_base/cartridge/controllers/Home.js'
touch('cartridges/app_storefront_base/cartridge/controllers/Home.js')
found = sfcc.resolve('~/cartridge/scripts/util', buf)
assert(#found == 1 and found[1]:find('app_storefront_base', 1, true))

-- directory require: main.js, then package.json "main" (no index.js)
touch('cartridges/app_custom/cartridge/scripts/lib/main.js')
touch('cartridges/app_custom/cartridge/scripts/pkg/entry.js')
vim.fn.writefile({ '{"main":"entry"}' }, root .. '/cartridges/app_custom/cartridge/scripts/pkg/package.json')
touch('cartridges/app_custom/cartridge/scripts/idx/index.js')
found = sfcc.resolve('*/cartridge/scripts/lib', '')
assert(#found == 1 and found[1]:find('lib/main%.js$'), 'directory require via main.js failed')
found = sfcc.resolve('*/cartridge/scripts/pkg', '')
assert(#found == 1 and found[1]:find('pkg/entry%.js$'), 'directory require via package.json main failed')
assert(#sfcc.resolve('*/cartridge/scripts/idx', '') == 0, 'index.js must not resolve (Prophet parity)')

-- explicit cartridge reference resolves inside that cartridge only
found = sfcc.resolve('app_storefront_base/cartridge/scripts/util', buf)
assert(#found == 1 and found[1]:find('app_storefront_base', 1, true), 'explicit cartridge reference failed')
assert(#sfcc.resolve('no_such_cartridge/cartridge/scripts/util', buf) == 0)

-- dw API modules, relative and absolute paths are left to builtin gf
assert(#sfcc.resolve('dw/system/Site', '') == 0)
assert(#sfcc.resolve('./cartridge/scripts/util', buf) == 0)
assert(#sfcc.resolve('/etc/hosts', buf) == 0)

-- outside a dw.json project, explicit references must not trigger a scan
local plain = vim.fn.tempname()
vim.fn.mkdir(plain .. '/lodash/fp', 'p')
vim.fn.writefile({}, plain .. '/lodash/fp/get.js')
assert(#sfcc.resolve('lodash/fp/get', plain .. '/index.js') == 0, 'bare module path must be ignored without dw.json')

print('OK')
