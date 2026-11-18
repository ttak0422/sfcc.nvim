local sfcc = require('sfcc')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))
local function write(rel, text)
  local path = root .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ text or '' }, path)
  return path
end

local hrtime, dir, now, scans = vim.uv.hrtime, vim.fs.dir, 0, 0
vim.uv.hrtime = function() return now end
vim.fs.dir = function(path, ...)
  if path == root then
    scans = scans + 1
  end
  return dir(path, ...)
end
vim.fn.chdir(root)
sfcc.reset()

-- An uninitialized submodule can leave a valid dw.json with no cartridges.
write('dw.json', '{"cartridgesPath":"app_custom:app_base:app_next"}')
vim.fn.mkdir(root .. '/sub', 'p')
local file = write('src/current.js')
assert(#sfcc.resolve('*/cartridge/scripts/util', file) == 0)
assert(scans == 1, 'initial miss must scan once')
write('sub/cartridges/app_base/cartridge/scripts/util.js')
-- Even distinct unresolved paths must reuse the same discovery snapshot.
for i = 1, 20 do
  now = i * 1e8
  assert(#sfcc.resolve('*/cartridge/scripts/missing' .. i, file) == 0)
  assert(#sfcc.resolve('missing_module' .. i, file) == 0)
end
now = 5e9 - 1
assert(#sfcc.resolve('*/cartridge/scripts/util', file) == 0)
assert(scans == 1, 'misses must not repeatedly scan during the five-second window')
now = 5e9
local found, ordered = sfcc.resolve('*/cartridge/scripts/util', file)
assert(#found == 1 and ordered, 'cartridges added after an initial miss must be discovered without reset')
assert(scans == 2, 'expired discovery must scan once')

-- File misses are never cached: files added inside a known cartridge work immediately.
assert(#sfcc.resolve('*/cartridge/scripts/late', file) == 0)
local late = write('sub/cartridges/app_base/cartridge/scripts/late.js')
found = sfcc.resolve('*/cartridge/scripts/late', file)
assert(#found == 1 and found[1] == late, 'new files in a known cartridge must resolve immediately')
assert(scans == 2, 'new files must not require another discovery scan')

-- A partial success must eventually include a newly available higher-priority cartridge.
local custom = write('sub/cartridges/app_custom/cartridge/scripts/util.js')
write('sub/cartridges/unlisted/cartridge/scripts/util.js')
write('node_modules/ignored/cartridge/scripts/util.js')
now = 10e9
found, ordered = sfcc.resolve('*/cartridge/scripts/util', file)
assert(ordered and #found == 2 and found[1] == custom, 'refresh must preserve dw.json order and whitelist')
assert(scans == 3, 'successful lookups must refresh expired discovery too')
found = sfcc.resolve('app_custom/cartridge/scripts/util', file)
assert(#found == 1 and found[1] == custom, 'explicit cartridge references must use refreshed roots')

-- gf must open the preferred target after recovery, without prompting.
vim.cmd.edit(file)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "require('*/cartridge/scripts/util')" })
vim.bo.modified = false
vim.api.nvim_win_set_cursor(0, { 1, 12 })
local select = vim.ui.select
vim.ui.select = function() error('ordered gf must not prompt') end
sfcc.gf()
vim.ui.select = select
assert(vim.api.nvim_buf_get_name(0) == custom, 'gf did not recover to the preferred cartridge')

-- Newly installed workspace modules recover through the same discovery cache.
assert(#sfcc.resolve('server', file) == 0)
local server = write('sub/modules/server/main.js')
now = 15e9
found = sfcc.resolve('server', file)
assert(#found == 1 and found[1] == server, 'modules added after a miss must recover without reset')
assert(scans == 4)

-- superModule also refreshes discovery when a lower-priority cartridge arrives.
local base = root .. '/sub/cartridges/app_base/cartridge/scripts/util.js'
assert(#sfcc.super(base) == 0)
local next_file = write('sub/cartridges/app_next/cartridge/scripts/util.js')
now = 20e9
found = sfcc.super(base)
assert(#found == 1 and found[1] == next_file, 'superModule must discover newly added cartridges')
assert(scans == 5)

-- Expired SFCC discovery must not interfere with aliases or fallback from a missing alias target.
write('tsconfig.json', '{"compilerOptions":{"paths":{"mapped":["src/target"],"*/cartridge/scripts/late":["missing"]}}}')
local target = write('src/target.js')
now = 25e9
found, ordered = sfcc.resolve('mapped', file)
assert(#found == 1 and found[1] == target and ordered, 'tsconfig alias precedence must survive discovery expiry')
assert(scans == 5, 'a matching alias must not trigger cartridge discovery')
found = sfcc.resolve('*/cartridge/scripts/late', file)
assert(#found == 1 and found[1] == late, 'missing tsconfig targets must preserve refreshed SFCC fallback')
assert(scans == 6)

-- Reset still forces an immediate refresh inside the reuse window.
local newest = write('sub/cartridges/app_next/cartridge/scripts/newest.js')
sfcc.reset()
found = sfcc.resolve('*/cartridge/scripts/newest', file)
assert(#found == 1 and found[1] == newest and scans == 7, 'reset must bypass the reuse window')

vim.uv.hrtime = hrtime
vim.fs.dir = dir
sfcc.reset()
print('cache: OK')
