-- sfcc.nvim: resolve SFCC cartridge require paths like require('*/cartridge/...')
local M = {}

local cache = {} -- project root -> { roots = {dir,...}, ordered = bool }

-- nearest ancestor with dw.json, or nil
local function dw_root(file)
  return vim.fs.root(file ~= '' and file or assert(vim.uv.cwd()), 'dw.json')
end

-- ordered cartridge names from dw.json: cartridgesPath, else the
-- `cartridge` array (Prophet's own fallback order)
local function read_cartridges_path(cwd)
  local f = io.open(cwd .. '/dw.json')
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

-- walk the tree without descending into node_modules / dot-dirs
-- (vim.fs.find can filter matches but cannot prune traversal)
local function walk(dir, acc)
  for name, kind in vim.fs.dir(dir) do
    if kind == 'directory' and name:sub(1, 1) ~= '.' and name ~= 'node_modules' then
      if name == 'cartridge' then
        table.insert(acc, dir)
      else
        walk(dir .. '/' .. name, acc)
      end
    end
  end
  return acc
end

-- cartridge roots = parents of directories literally named `cartridge`
local function cartridge_roots(proj)
  local hit = cache[proj]
  if hit then
    return hit.roots, hit.ordered
  end
  local roots = walk(proj, {})

  -- Prophet semantics: the dw.json cartridge list is both the order and the
  -- whitelist — walk the declared names and pick matching roots; names with
  -- no folder are skipped. Only when nothing matches do we degrade to the
  -- unordered full list (Prophet would resolve nothing there).
  local order = read_cartridges_path(proj)
  local ordered = false
  if order then
    local by_name = {}
    for _, r in ipairs(roots) do
      local name = vim.fs.basename(r)
      by_name[name] = by_name[name] or {}
      table.insert(by_name[name], r)
    end
    local picked = {}
    for _, name in ipairs(order) do
      for _, r in ipairs(by_name[name] or {}) do
        table.insert(picked, r)
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
    roots, ordered = cartridge_roots(dw_root(file) or assert(vim.uv.cwd()))
  elseif spec:match('^~/') then
    rest = spec:match('^~/(.+)')
    roots = { vim.fs.root(file, 'cartridge') }
  elseif spec:match('^[%w_%-]+/') and not spec:match('^dw/') then
    -- explicit cartridge reference, e.g. require('app_storefront_base/...').
    -- Gated on dw.json: bare module paths ('lodash/fp') are common in any JS
    -- project and must not trigger a workspace scan.
    local proj = dw_root(file)
    if not proj then
      return {}, false
    end
    local name
    name, rest = spec:match('^([^/]+)/(.+)')
    local all
    all, ordered = cartridge_roots(proj)
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

return M
