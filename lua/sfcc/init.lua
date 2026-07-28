-- sfcc.nvim: resolve SFCC cartridge require paths like require('*/cartridge/...')
local M = {}

local cache = {} -- project root -> { roots = {dir,...}, ordered = bool, modules = dir? }

-- quick project lookup without scanning: the workspace (cwd) when it has a
-- dw.json, else the nearest ancestor of the file with one. The cwd wins so a
-- submodule shipping its own dw.json cannot shadow the workspace config.
local function project(file)
  local cwd = assert(vim.uv.cwd())
  if vim.fn.filereadable(cwd .. '/dw.json') == 1 then
    return cwd, cwd .. '/dw.json'
  end
  local anc = vim.fs.root(file ~= '' and file or cwd, 'dw.json')
  if anc then
    return anc, anc .. '/dw.json'
  end
  return cwd, nil
end

-- ordered cartridge names from a dw.json file: cartridgesPath, else the
-- `cartridge` array (Prophet's own fallback order)
local function read_cartridges_path(dwfile)
  local f = io.open(dwfile)
  if not f then
    return nil
  end
  local ok, json = pcall(vim.json.decode, f:read('*a'))
  f:close()
  if not ok or type(json) ~= 'table' then
    return nil
  end
  local raw = json.cartridgesPath or json.cartridgePath
  local parts = type(raw) == 'string' and vim.split(raw, '[:,]', { trimempty = true })
    or type(json.cartridge) == 'table' and json.cartridge
    or {}
  local names = {}
  for _, name in ipairs(parts) do
    name = type(name) == 'string' and vim.trim(name) or ''
    if name ~= '' then
      table.insert(names, name)
    end
  end
  return #names > 0 and names or nil
end

-- walk the tree without descending into node_modules / dot-dirs, collecting
-- cartridge roots and dw.json locations in one pass
-- (vim.fs.find can filter matches but cannot prune traversal)
local function walk(dir, acc)
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name == 'dw.json' then
      table.insert(acc.configs, dir .. '/dw.json')
    elseif kind == 'directory' and name:sub(1, 1) ~= '.' and name ~= 'node_modules' then
      if name == 'cartridge' then
        table.insert(acc.roots, dir)
      else
        if name == 'modules' then
          -- the SFRA shared-modules folder: bare requires resolve into it,
          -- like Prophet's implicit ":modules" cartridge-path entry
          table.insert(acc.modules, dir .. '/modules')
        end
        walk(dir .. '/' .. name, acc)
      end
    end
  end
  return acc
end

local function shallow_first(a, b)
  local _, da = a:gsub('/', '')
  local _, db = b:gsub('/', '')
  if da ~= db then
    return da < db
  end
  return a < b
end

-- cartridge roots = parents of directories literally named `cartridge`
local function cartridge_roots(proj, config)
  local hit = cache[proj]
  if hit then
    return hit.roots, hit.ordered, hit.modules
  end
  local acc = walk(proj, { roots = {}, configs = {}, modules = {} })
  -- deterministic, and first-per-name below prefers the shallowest copy
  table.sort(acc.roots, shallow_first)
  table.sort(acc.modules, shallow_first)
  if not config then
    table.sort(acc.configs, shallow_first)
    config = acc.configs[1]
  end

  -- one folder per cartridge name in every mode, shallowest copy wins: a
  -- duplicated checkout (e.g. a git submodule) is the same cartridge, so the
  -- priority rule alone decides and no picker should ever offer both
  local by_name, uniq = {}, {}
  for _, r in ipairs(acc.roots) do
    local name = vim.fs.basename(r)
    if not by_name[name] then
      by_name[name] = r
      table.insert(uniq, r)
    end
  end

  -- Prophet semantics: the dw.json cartridge list is both the order and the
  -- whitelist — walk the declared names; names with no folder are skipped.
  -- Only when nothing matches do we degrade to the unordered deduped list
  -- (Prophet would resolve nothing).
  local order = config and read_cartridges_path(config)
  local roots, ordered = uniq, false
  if order then
    local picked = {}
    for _, name in ipairs(order) do
      if by_name[name] then
        table.insert(picked, by_name[name])
      end
    end
    if #picked > 0 then
      roots, ordered = picked, true
    end
  end
  cache[proj] = { roots = roots, ordered = ordered, modules = acc.modules[1] }
  return roots, ordered, acc.modules[1]
end

-- Prophet 1.4.x tries ''/.d.ts/.js/.json/.ts. Divergences: .ds is kept for
-- legacy SiteGenesis (upstream dropped it), and .d.ts goes last instead of
-- second — jumping to typings when the implementation exists is worse UX.
local exts = { '', '.js', '.ds', '.json', '.ts', '.d.ts' }

local function first_existing(base)
  for _, ext in ipairs(exts) do
    if vim.fn.filereadable(base .. ext) == 1 then
      return base .. ext
    end
  end
end

local function existing_file(base)
  local hit = first_existing(base)
  if hit then
    return hit
  end
  -- directory require, like Prophet: <dir>/main.js or package.json "main"
  -- with the same extension attempts (no index.js convention upstream either)
  if vim.fn.isdirectory(base) == 1 then
    if vim.fn.filereadable(base .. '/main.js') == 1 then
      return base .. '/main.js'
    end
    local f = io.open(base .. '/package.json')
    if f then
      local ok, json = pcall(vim.json.decode, f:read('*a'))
      f:close()
      if ok and type(json) == 'table' and type(json.main) == 'string' then
        return first_existing(base .. '/' .. json.main)
      end
    end
  end
end

--- Resolve a require spec to existing files, in cartridge-path order.
---@param spec string "*/..." | "~/..." | "./..." | "<cartridge_name>/..." | "<modules path>"
---@param file string buffer file path (used for "~", "." and to locate dw.json)
---@return string[] found
---@return boolean ordered true when dw.json cartridgesPath defined the order
function M.resolve(spec, file)
  spec = spec:gsub('^/', '') -- Prophet accepts one leading slash on any form
  local candidates, ordered = {}, false
  local rest = spec:match('^%*/(.+)')
  if rest then
    local proj, config = project(file)
    local roots
    roots, ordered = cartridge_roots(proj, config)
    for _, root in ipairs(roots) do
      table.insert(candidates, root .. '/' .. rest)
    end
  elseif spec:match('^~/') then
    local root = vim.fs.root(file, 'cartridge')
    if root then
      table.insert(candidates, root .. '/' .. spec:sub(3))
    end
  elseif spec:match('^%.%.?/') then
    -- relative require, with the same extension attempts as cartridge paths
    -- (Prophet 1.4.x resolves these itself instead of leaving them to the
    -- editor). Gated on a script buffer inside a dw.json project, so a
    -- global gf mapping never shadows filetype-aware builtin gf elsewhere
    -- (e.g. scss @import './variables' must keep resolving to .scss).
    if file == '' or not (file:match('%.[jt]s$') or file:match('%.ds$') or file:match('%.isml$')) then
      return {}, false
    end
    local proj, config = project(file)
    if not config and not cache[proj] then
      return {}, false
    end
    -- no vim.fs.normalize here: it expands $VARS and collapses '..'
    -- textually, both of which break real paths; the OS handles ./ and ..
    table.insert(candidates, vim.fs.dirname(file) .. '/' .. (spec:gsub('^%./', '')))
  elseif spec:match('^dw/') then
    return {}, false
  else
    -- explicit cartridge reference (require('app_storefront_base/...')) or a
    -- bare path into the workspace `modules` folder (require('server')).
    -- Charset check first: junk strings (sentences, URLs) bail without
    -- touching the filesystem.
    if not spec:match('^[%w_%-%./]+$') then
      return {}, false
    end
    -- Gated on a quickly-findable dw.json (or an already-discovered project):
    -- bare module paths ('lodash/fp') are common in any JS project and must
    -- not trigger a workspace scan.
    local proj, config = project(file)
    if not config and not cache[proj] then
      return {}, false
    end
    local all, modules
    all, ordered, modules = cartridge_roots(proj, config)
    local name, sub = spec:match('^([^/]+)/(.+)')
    if name then
      for _, r in ipairs(all) do
        if vim.fs.basename(r) == name then
          table.insert(candidates, r .. '/' .. sub)
        end
      end
    end
    if modules then
      table.insert(candidates, modules .. '/' .. spec)
    end
  end
  local found = {}
  for _, base in ipairs(candidates) do
    local hit = existing_file(base)
    if hit then
      table.insert(found, hit)
    end
  end
  return found, ordered
end

--- module.superModule: the same cartridge-relative path in the next cartridge
--- down the declared order (like Prophet, only resolvable when dw.json
--- defines the order — "next" is meaningless otherwise).
---@param file string buffer file path
---@return string[] found
function M.super(file)
  local root = file ~= '' and vim.fs.root(file, 'cartridge')
  if not root then
    return {}
  end
  local proj, config = project(file)
  local roots, ordered = cartridge_roots(proj, config)
  if not ordered then
    return {}
  end
  local name = vim.fs.basename(root)
  local rel = file:sub(#root + 2):gsub('%.js$', '')
  local below = false
  for _, r in ipairs(roots) do
    if vim.fs.basename(r) == name then
      below = true
    elseif below then
      local hit = existing_file(r .. '/' .. rel)
      if hit then
        return { hit }
      end
    end
  end
  return {}
end

local function spec_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for s, str, e in line:gmatch('()["\']([^"\']+)["\']()') do
    if col >= s and col < e then
      return str
    end
  end
end

local function super_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for s, e in line:gmatch('()module%.superModule()') do
    if col >= s and col < e then
      return true
    end
  end
end

--- gf replacement: jump to the cartridge file under cursor, fall back to builtin gf.
function M.gf()
  local spec = spec_under_cursor()
  local found, ordered = {}, false
  if spec then
    found, ordered = M.resolve(spec, vim.api.nvim_buf_get_name(0))
  elseif super_under_cursor() then
    found, ordered = M.super(vim.api.nvim_buf_get_name(0)), true
    if #found == 0 then
      return vim.notify(
        'sfcc.nvim: no superModule target (needs a dw.json cartridge order and a lower-priority copy)',
        vim.log.levels.INFO
      )
    end
  end
  if #found == 0 then
    if spec and spec:match('^/?dw/') then
      return vim.notify('sfcc.nvim: "' .. spec .. '" is a dw.* API module (no file)', vim.log.levels.INFO)
    end
    local ok, err = pcall(vim.cmd, 'normal! gf')
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return
  end
  -- dw.json cartridgesPath defines a priority order: first match wins,
  -- exactly like Prophet / Business Manager. Ask only when order is unknown.
  if #found == 1 or ordered then
    return vim.cmd.edit(found[1])
  end
  vim.ui.select(found, { prompt = 'SFCC cartridge file' }, function(choice)
    if choice then
      vim.cmd.edit(choice)
    end
  end)
end

--- Drop the cartridge-roots cache (e.g. after adding a cartridge).
function M.reset()
  cache = {}
end

--- Uncached discovery snapshot for :checkhealth sfcc.
---@return { workspace: string, config: string?, order: string[]?, roots: string[], modules: string? }
function M.info()
  local proj, config = project(vim.api.nvim_buf_get_name(0))
  local acc = walk(proj, { roots = {}, configs = {}, modules = {} })
  table.sort(acc.roots, shallow_first)
  table.sort(acc.modules, shallow_first)
  if not config then
    table.sort(acc.configs, shallow_first)
    config = acc.configs[1]
  end
  return {
    workspace = proj,
    config = config,
    order = config and read_cartridges_path(config) or nil,
    roots = acc.roots,
    modules = acc.modules[1],
  }
end

return M
