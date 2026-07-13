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

-- unknown prefixes are left to builtin gf
assert(#sfcc.resolve('dw/system/Site', '') == 0)

print('OK')
