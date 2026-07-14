-- sfcc.nvim: resolve SFCC cartridge require paths like require('*/cartridge/...')
local M = {}

local cache = {} -- project root -> { roots = {dir,...}, ordered = bool }

-- nearest ancestor with dw.json, or nil
local function dw_root(file)
  return vim.fs.root(file ~= '' and file or assert(vim.uv.cwd()), 'dw.json')
end

local function read_cartridges_path(cwd)
  local f = io.open(cwd .. '/dw.json')
  if not f then
    return nil
  end
  local ok, json = pcall(vim.json.decode, f:read('*a'))
  f:close()
  if not ok then
    return nil
  end
  local raw = json.cartridgesPath or json.cartridgePath
  if type(raw) ~= 'string' then
    return nil
  end
  return vim.split(raw, '[:,]', { trimempty = true })
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

  -- order by dw.json cartridgesPath ("app_custom:app_storefront_base") when present
  local order = read_cartridges_path(proj)
  if order then
    local rank = {}
    for i, name in ipairs(order) do
      rank[name] = i
    end
    table.sort(roots, function(a, b)
      local ra = rank[vim.fs.basename(a)] or math.huge
      local rb = rank[vim.fs.basename(b)] or math.huge
      if ra == rb then
        return a < b
      end
      return ra < rb
    end)
  end
  cache[proj] = { roots = roots, ordered = order ~= nil }
  return roots, order ~= nil
end

local function existing_file(base)
  for _, ext in ipairs { '', '.js', '.ds', '.json' } do
    if vim.fn.filereadable(base .. ext) == 1 then
      return base .. ext
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
