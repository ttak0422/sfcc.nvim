-- sfcc.nvim: resolve SFCC cartridge require paths like require('*/cartridge/...')
local M = {}

local cache = {} -- project root -> { roots = {dir,...}, ordered = bool }

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
    return hit.roots, hit.ordered
  end
  local acc = walk(proj, { roots = {}, configs = {} })
  -- deterministic, and first-per-name below prefers the shallowest copy
  table.sort(acc.roots, shallow_first)
  if not config then
    table.sort(acc.configs, shallow_first)
    config = acc.configs[1]
  end

  -- Prophet semantics: the dw.json cartridge list is both the order and the
  -- whitelist — walk the declared names, one folder per name (a duplicated
  -- checkout, e.g. a git submodule, must not yield duplicate candidates);
  -- names with no folder are skipped. Only when nothing matches do we
  -- degrade to the unordered full list (Prophet would resolve nothing).
  local order = config and read_cartridges_path(config)
  local roots, ordered = acc.roots, false
  if order then
    local by_name = {}
    for _, r in ipairs(roots) do
      local name = vim.fs.basename(r)
      if not by_name[name] then
        by_name[name] = r
      end
    end
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
  cache[proj] = { roots = roots, ordered = ordered }
  return roots, ordered
end

local function existing_file(base)
  for _, ext in ipairs { '', '.js', '.ds', '.json' } do
    if vim.fn.filereadable(base .. ext) == 1 then
      return base .. ext
    end
  end
  -- directory require, like Prophet: <dir>/main.js or package.json "main"
  -- (no index.js convention upstream either)
  if vim.fn.isdirectory(base) == 1 then
    if vim.fn.filereadable(base .. '/main.js') == 1 then
      return base .. '/main.js'
    end
    local f = io.open(base .. '/package.json')
    if f then
      local ok, json = pcall(vim.json.decode, f:read('*a'))
      f:close()
      if ok and type(json) == 'table' and type(json.main) == 'string' then
        local main = base .. '/' .. json.main
        if not main:match('%.js$') then
          main = main .. '.js'
        end
        if vim.fn.filereadable(main) == 1 then
          return main
        end
      end
    end
  end
end

--- Resolve a require spec to existing files, in cartridge-path order.
---@param spec string "*/cartridge/..." | "~/cartridge/..." | "<cartridge_name>/..."
---@param file string buffer file path (used for "~" and to locate dw.json)
---@return string[] found
---@return boolean ordered true when dw.json cartridgesPath defined the order
function M.resolve(spec, file)
  local roots, ordered = nil, false
  local rest = spec:match('^%*/(.+)')
  if rest then
    local proj, config = project(file)
    roots, ordered = cartridge_roots(proj, config)
  elseif spec:match('^~/') then
    rest = spec:match('^~/(.+)')
    roots = { vim.fs.root(file, 'cartridge') }
  elseif spec:match('^[%w_%-]+/') and not spec:match('^dw/') then
    -- explicit cartridge reference, e.g. require('app_storefront_base/...').
    -- Gated on a quickly-findable dw.json: bare module paths ('lodash/fp')
    -- are common in any JS project and must not trigger a workspace scan.
    local proj, config = project(file)
    if not config then
      return {}, false
    end
    local name
    name, rest = spec:match('^([^/]+)/(.+)')
    local all
    all, ordered = cartridge_roots(proj, config)
    roots = {}
    for _, r in ipairs(all) do
      if vim.fs.basename(r) == name then
        table.insert(roots, r)
      end
    end
  else
    return {}, false
  end
  local found = {}
  for _, root in ipairs(roots) do
    local hit = existing_file(root .. '/' .. rest)
    if hit then
      table.insert(found, hit)
    end
  end
  return found, ordered
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

--- gf replacement: jump to the cartridge file under cursor, fall back to builtin gf.
function M.gf()
  local spec = spec_under_cursor()
  local found, ordered = {}, false
  if spec then
    found, ordered = M.resolve(spec, vim.api.nvim_buf_get_name(0))
  end
  if #found == 0 then
    if spec and spec:match('^dw/') then
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
---@return { workspace: string, config: string?, order: string[]?, roots: string[] }
function M.info()
  local proj, config = project(vim.api.nvim_buf_get_name(0))
  local acc = walk(proj, { roots = {}, configs = {} })
  table.sort(acc.roots, shallow_first)
  if not config then
    table.sort(acc.configs, shallow_first)
    config = acc.configs[1]
  end
  return {
    workspace = proj,
    config = config,
    order = config and read_cartridges_path(config) or nil,
    roots = acc.roots,
  }
end

return M
