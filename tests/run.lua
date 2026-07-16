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

-- declared order must win even against alphabetical order, spaces and all
vim.fn.writefile({ '{"cartridgesPath":"app_storefront_base : app_custom"}' }, root .. '/dw.json')
sfcc.reset()
found, ordered = sfcc.resolve('*/cartridge/scripts/util', '')
assert(ordered and found[1]:find('app_storefront_base', 1, true), 'declared order must beat alphabetical order')

-- the list is also a whitelist: unlisted cartridges are excluded (Prophet parity)
vim.fn.writefile({ '{"cartridgesPath":"app_storefront_base"}' }, root .. '/dw.json')
sfcc.reset()
found = sfcc.resolve('*/cartridge/scripts/util', '')
assert(#found == 1 and found[1]:find('app_storefront_base', 1, true), 'whitelist not applied')

-- when no declared name exists on disk, degrade to the unordered full list
vim.fn.writefile({ '{"cartridgesPath":"missing_a:missing_b"}' }, root .. '/dw.json')
sfcc.reset()
found, ordered = sfcc.resolve('*/cartridge/scripts/util', '')
assert(#found == 2 and not ordered, 'must degrade to unordered when nothing matches')

-- the `cartridge` array is the fallback order source, like Prophet
vim.fn.writefile({ '{"cartridge":["app_storefront_base","app_custom"]}' }, root .. '/dw.json')
sfcc.reset()
found, ordered = sfcc.resolve('*/cartridge/scripts/util', '')
assert(ordered and found[1]:find('app_storefront_base', 1, true), 'cartridge array fallback failed')

-- a duplicated cartridge (e.g. a git submodule checkout) yields ONE
-- candidate per declared name, and the shallowest copy wins
touch('sub/sfra/cartridges/app_custom/cartridge/scripts/util.js')
vim.fn.writefile({ '{"cartridgesPath":"app_custom:app_storefront_base"}' }, root .. '/dw.json')
sfcc.reset()
found, ordered = sfcc.resolve('*/cartridge/scripts/util', '')
assert(ordered and #found == 2, 'duplicate cartridge must not duplicate candidates, got ' .. #found)
assert(not found[1]:find('/sub/', 1, true), 'shallowest copy must win: ' .. found[1])

-- a dw.json below the workspace root (not an ancestor of the sources) is
-- still found by the scan
local proj2 = vim.fn.tempname()
local function touch2(rel)
  local p = proj2 .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  vim.fn.writefile({}, p)
end
touch2('cartridges/c_a/cartridge/scripts/x.js')
touch2('cartridges/c_b/cartridge/scripts/x.js')
touch2('conf/keep')
vim.fn.writefile({ '{"cartridgesPath":"c_b:c_a"}' }, proj2 .. '/conf/dw.json')
vim.fn.chdir(proj2)
sfcc.reset()
found, ordered = sfcc.resolve('*/cartridge/scripts/x', proj2 .. '/cartridges/c_a/cartridge/scripts/x.js')
assert(ordered and found[1]:find('c_b', 1, true), 'nested dw.json not honored')

-- a submodule shipping its own dw.json must not shadow the workspace config
local proj3 = vim.fn.tempname()
local function touch3(rel)
  local p = proj3 .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  vim.fn.writefile({}, p)
end
touch3('cartridges/m_a/cartridge/scripts/y.js')
touch3('sub/cartridges/m_b/cartridge/scripts/y.js')
vim.fn.writefile({ '{"cartridgesPath":"m_b:m_a"}' }, proj3 .. '/dw.json')
vim.fn.writefile({ '{"cartridgesPath":"m_b"}' }, proj3 .. '/sub/dw.json')
vim.fn.chdir(proj3)
sfcc.reset()
found, ordered = sfcc.resolve('*/cartridge/scripts/y', proj3 .. '/sub/cartridges/m_b/cartridge/scripts/y.js')
assert(ordered and #found == 2 and found[1]:find('m_b', 1, true), 'workspace dw.json must win over the submodule one')

-- outside a dw.json project, explicit references must not trigger a scan
local plain = vim.fn.tempname()
vim.fn.mkdir(plain .. '/lodash/fp', 'p')
vim.fn.chdir(plain)
vim.fn.writefile({}, plain .. '/lodash/fp/get.js')
assert(#sfcc.resolve('lodash/fp/get', plain .. '/index.js') == 0, 'bare module path must be ignored without dw.json')

-- health snapshot (compare realpaths: on macOS tempname goes through /var -> /private/var)
vim.fn.chdir(root)
local real = assert(vim.uv.fs_realpath(root))
local info = sfcc.info()
assert(info.workspace == real and info.config == real .. '/dw.json', 'info() picked the wrong project')
assert(#info.roots >= 2 and info.order ~= nil, 'info() snapshot incomplete')

print('OK')
