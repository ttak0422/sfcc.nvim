local sfcc = require('sfcc')
local tsconfig = require('sfcc.tsconfig')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))

local function write(rel, text)
  local path = root .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(vim.split(text or '', '\n', { plain = true }), path)
  return path
end

local file = write('src/current.js')
local function config(text)
  write('tsconfig.json', text)
  sfcc.reset()
end

local checks = 0
local function expect(spec, rel, from, want_ordered)
  checks = checks + 1
  local found, ordered = sfcc.resolve(spec, from or file)
  if not rel then
    assert(#found == 0, spec .. ': unexpected hit ' .. vim.inspect(found))
  else
    assert(#found == 1 and ordered == (want_ordered ~= false), spec .. ': unexpected hits/order ' .. vim.inspect(found))
    assert(vim.uv.fs_realpath(found[1]) == vim.uv.fs_realpath(root .. '/' .. rel),
      spec .. ': expected ' .. rel .. ', got ' .. found[1])
  end
end

vim.fn.chdir(root)
write('src/util.js')
write('src/exact.ts')
write('src/fallback.ts')
write('src/second.ts')
write('src/pkg/main.js')
write('src/typed.d.ts')
write('src/pkg2/package.json', '{"main":"entry"}')
write('src/pkg2/entry.ts')
write('src/idx/index.js')

-- JSONC, BOM, scoped aliases, exact match, ordered targets and baseUrl.
-- URL and comment-marker strings must survive comment/trailing-comma removal.
config('\239\187\191' .. [[{
  // line comment
  "compilerOptions": {
    "baseUrl": "./src",
    "paths": {
      "@app/*": ["*"], /* block comment */
      "@app/util": ["exact"],
      "fallback": ["missing", "fallback", "second",],
      "url": ["https://example.invalid/a/*", "fallback"],
      "literal": ["literal,}.js"],
      "$alias": ["$literal%name"],
      "quote": ["escaped\"quote"],
    },
  },
}]])
write('src/literal,}.js')
write('src/$literal%name.js')
write('src/escaped"quote.js')
expect('@app/util', 'src/exact.ts')
expect('@app/fallback', 'src/fallback.ts')
expect('fallback', 'src/fallback.ts')
expect('url', 'src/fallback.ts')
expect('literal', 'src/literal,}.js')
expect('$alias', 'src/$literal%name.js')
expect('quote', 'src/escaped"quote.js')
expect('@app/pkg', 'src/pkg/main.js')
expect('@app/pkg2', 'src/pkg2/entry.ts')
expect('@app/typed', 'src/typed.d.ts')
expect('@app/idx', nil) -- retain Prophet directory rules
expect('@app/util', nil, root .. '/src/main.scss')
expect('./util', nil) -- no dw.json: preserve the existing relative-import gate
expect('@app/util', 'src/exact.ts', '') -- unnamed buffer uses cwd
assert(#tsconfig.info(file).errors == 0, vim.inspect(tsconfig.info(file).errors))

-- No baseUrl is needed. Prefix/suffix comparisons are literal, and * can
-- capture an empty string or a string containing slashes.
write('other/deep/item.js')
write('other/suffix.js')
write('other/.js')
config([[{"compilerOptions":{"paths":{
  "@scope/*/end":["other/*"],
  "a.b+/*":["other/*"],
  "empty*":["other/*"]
}}}]])
expect('@scope/deep/item/end', 'other/deep/item.js')
expect('@scope/suffix/end', 'other/suffix.js')
expect('@scope/suffix/end/extra', nil)
expect('a.b+/suffix', 'other/suffix.js')
expect('axb/suffix', nil)
expect('empty', 'other/.js')

-- Exact match, then longest wildcard prefix; no fallback to weaker patterns.
config([[{"compilerOptions":{"paths":{
  "*": ["src/second"],
  "a/*": ["src/fallback"],
  "a/b/*": ["src/exact"],
  "a/b/c": ["src/util"],
  "a/b/missing": ["missing"],
  "a/b/dead/*": ["missing"]
}}}]])
expect('a/b/c', 'src/util.js')
expect('a/b/other', 'src/exact.ts')
expect('a/other', 'src/fallback.ts')
expect('unmatched', 'src/second.ts')
expect('a/b/missing', nil)
expect('a/b/dead/end', nil)

-- Equal wildcard prefix lengths use declaration order, not suffix length or
-- Lua hash order. Escaped JSON property names are decoded before matching.
config([[{"compilerOptions":{"paths":{
  "foo\u002f*": ["src/util"], "foo/*bar": ["src/exact"]
}}}]])
expect('foo/xbar', 'src/util.js')
config([[{"compilerOptions":{"paths":{
  "foo/*bar": ["src/exact"], "foo/*": ["src/util"]
}}}]])
expect('foo/xbar', 'src/exact.ts')
config([[{"compilerOptions":{"paths":{"foo/*":["missing"]}},
  "compilerOptions":{"paths":{"foo/*bar":["src/exact"],"foo/*":["src/util"]}}
}]])
expect('foo/xbar', 'src/exact.ts')
assert(#tsconfig.info(file).errors == 0)

-- Inheritance keeps the declaring directory for baseUrl and for paths
-- without baseUrl. A child replaces the map rather than merging aliases.
write('configs/base.json', '{"compilerOptions":{"paths":{"parent":["../src/util"]}}}')
config('{"extends":"./configs/base"}')
expect('parent', 'src/util.js')
config('{"extends":"./configs/base","compilerOptions":{"paths":{"child":["src/exact"]}}}')
expect('parent', nil)
expect('child', 'src/exact.ts')
config('{"extends":"./configs/base","compilerOptions":{"paths":{}}}')
expect('parent', nil)
write('configs/base.json', '{"compilerOptions":{"baseUrl":"../src","paths":{"parent":["util"]}}}')
config('{"extends":"./configs/base","compilerOptions":{"paths":{"child":["exact"]}}}')
expect('child', 'src/exact.ts')
expect('parent', nil)
write('other/util.js')
config('{"extends":"./configs/base","compilerOptions":{"baseUrl":"other"}}')
expect('parent', 'other/util.js')
config('{"extends":' .. vim.json.encode(root .. '/configs/base.json') .. '}')
expect('parent', 'src/util.js')

-- Multiple extends: later configs override only the options they provide.
write('configs/second.json', '{"compilerOptions":{"paths":{"second":["exact"]}}}')
config('{"extends":["./configs/base","./configs/second"]}')
expect('parent', nil)
expect('second', 'src/exact.ts')

-- Package configs via package.json tsconfig, default tsconfig.json, and
-- explicit subpaths. Search ancestor node_modules from the extending file.
write('node_modules/@test/config/package.json', '{"tsconfig":"settings/base.json"}')
write('node_modules/@test/config/settings/base.json', '{"compilerOptions":{"paths":{"package":["../../../../src/util"]}}}')
write('configs/nested.json', '{"extends":"@test/config"}')
config('{"extends":"./configs/nested"}')
expect('package', 'src/util.js')

-- TypeScript accepts backslash separators even on Unix. ${configDir} is
-- substituted after inheritance, relative to the consuming config.
write('configs/windows.json', '{"compilerOptions":{"paths":{"windows":["..\\\\src\\\\util"]}}}')
config('{"extends":".\\\\configs\\\\windows"}')
expect('windows', 'src/util.js')
config('{"compilerOptions":{"baseUrl":".\\\\src","paths":{"windows":["util"]}}}')
expect('windows', 'src/util.js')
config('{"compilerOptions":{"paths":{"windows":[".\\\\src\\\\util"]}}}')
expect('windows', 'src/util.js')
write('configs/template.json', [[{"compilerOptions":{
  "baseUrl":"${configDir}/src", "paths":{"template":["util"]}
}}]])
config('{"extends":"./configs/template"}')
expect('template', 'src/util.js')
write('configs/template.json', [[{"compilerOptions":{
  "paths":{"template":["${configDir}\\src\\exact"]}
}}]])
config('{"extends":"./configs/template"}')
expect('template', 'src/exact.ts')
config([[{"compilerOptions":{"paths":{"template":["${configDir}src/util"]}}}]])
expect('template', 'src/util.js')
write('node_modules/default-config/tsconfig.json', '{"compilerOptions":{"paths":{"default":["../../src/exact"]}}}')
config('{"extends":"default-config"}')
expect('default', 'src/exact.ts')
config('{"extends":"@test/config/settings/base"}')
expect('package', 'src/util.js')

-- Nearest config wins, even with cwd elsewhere. Parent aliases are not
-- implicitly merged and a sibling config cannot leak through a cache hit.
write('nested/tsconfig.json', '{"compilerOptions":{"paths":{"local":["../src/util"]}}}')
local nested = write('nested/deep/main.js')
config('{"compilerOptions":{"paths":{"root":["src/exact"]}}}')
expect('root', 'src/exact.ts')
expect('root', nil, nested)
expect('local', 'src/util.js', nested)
vim.fn.chdir('/tmp')
expect('local', 'src/util.js', nested)
expect('root', 'src/exact.ts')
vim.fn.chdir(root)

-- Cache invalidation includes inherited files; health requests a fresh view.
write('configs/cache.json', '{"compilerOptions":{"paths":{"cached":["../src/util"]}}}')
config('{"extends":"./configs/cache"}')
expect('cached', 'src/util.js')
write('configs/cache.json', '{"compilerOptions":{"paths":{"cached":["../src/exact"]}}}')
expect('cached', 'src/util.js')
assert(tsconfig.info(file, true).paths.cached[1] == '../src/exact')
sfcc.reset()
expect('cached', 'src/exact.ts')

-- Invalid input, missing parents, cycles and malformed entries never throw.
-- Valid local entries still work when an inherited config is missing.
for _, text in ipairs({ '{invalid', '{/* unfinished', 'null', '[]',
  '{"extends":false}', '{"compilerOptions":{"paths":null}}',
  '{"extends":"bad\\u0000name"}',
  '{"compilerOptions":{"baseUrl":"src\\u0000bad","paths":{"bad":["util"]}}}',
  '{"compilerOptions":{"paths":{"bad":["src/\\u0000util"]}}}',
  '{"compilerOptions":{"paths":{"bad**":["src/util"],"empty":[],"wrong":true}}}' }) do
  config(text)
  expect('bad', nil)
  assert(#tsconfig.info(file).errors > 0, 'missing diagnostics for ' .. text)
end
config('{"extends":"./missing","compilerOptions":{"paths":{"local":["src/util"]}}}')
expect('local', 'src/util.js')
assert(#tsconfig.info(file).errors == 1)
write('configs/cycle.json', '{"extends":"../tsconfig"}')
config('{"extends":"./configs/cycle","compilerOptions":{"paths":{"cycle":["src/util"]}}}')
expect('cycle', 'src/util.js')
assert(#tsconfig.info(file).errors == 1, 'cycle must be diagnosed without recursion')

-- Explicit tsconfig mappings win over dw.json, cartridge and module paths.
-- Missing aliases and targets preserve the existing SFCC fallbacks.
write('dw.json', '{"cartridgesPath":"app_a:app_b"}')
write('cartridges/app_a/cartridge/scripts/util.js')
write('cartridges/app_b/cartridge/scripts/util.js')
write('modules/server/main.js')
write('types/dw/system/Site.d.ts')
config([[{"compilerOptions":{"paths":{
  "*/cartridge/scripts/util": ["src/util"],
  "server": ["src/exact"],
  "dw/*": ["types/dw/*"],
  "app_b/*": ["missing/*"]
}}}]])
expect('*/cartridge/scripts/util', 'src/util.js')
expect('server', 'src/exact.ts')
expect('dw/system/Site', 'types/dw/system/Site.d.ts')
expect('dw/system/Missing', nil)
expect('app_b/cartridge/scripts/util', 'cartridges/app_b/cartridge/scripts/util.js')
expect('./util', 'src/util.js', file, false)
local supers = sfcc.super(root .. '/cartridges/app_a/cartridge/scripts/util.js')
assert(#supers == 1 and supers[1]:find('app_b', 1, true), 'tsconfig must not affect superModule')
config('{"compilerOptions":{"paths":{"*/cartridge/scripts/util":["missing"]}}}')
local found, ordered = sfcc.resolve('*/cartridge/scripts/util', file)
assert(#found == 2 and ordered and found[1]:find('app_a', 1, true), 'missing mapping broke cartridge fallback')
config('{"compilerOptions":{"baseUrl":"src"}}')
expect('util', nil) -- baseUrl alone is intentionally not a bare-import resolver

-- A gf integration check: alias target precedence opens one file, no picker.
config('{"compilerOptions":{"paths":{"jump":["src/util","src/exact"]}}}')
vim.cmd.edit(file)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "require('jump')" })
vim.bo.modified = false
vim.api.nvim_win_set_cursor(0, { 1, 10 })
local select = vim.ui.select
vim.ui.select = function() error('paths must not prompt for selection') end
sfcc.gf()
vim.ui.select = select
assert(vim.api.nvim_buf_get_name(0) == root .. '/src/util.js', 'gf did not open alias target')
assert(sfcc.info().tsconfig.file == root .. '/tsconfig.json', 'health snapshot lacks tsconfig')
-- The user-facing health check reports parse/extends errors rather than
-- throwing, and includes the chosen config before any dw.json diagnostics.
config('{"extends":"./missing","compilerOptions":{"paths":{"jump":["src/util"]}}}')
local health, messages = vim.health, {}
vim.health = {}
for _, level in ipairs({ 'start', 'info', 'ok', 'warn', 'error' }) do
  vim.health[level] = function(message) table.insert(messages, message) end
end
require('sfcc.health').check()
vim.health = health
local report = table.concat(messages, '\n')
assert(report:find('tsconfig: ' .. root .. '/tsconfig.json', 1, true), 'health omitted tsconfig')
assert(report:find('cannot resolve extends ./missing', 1, true), 'health omitted extends failure')
print(('tsconfig: %d resolution checks OK'):format(checks))
