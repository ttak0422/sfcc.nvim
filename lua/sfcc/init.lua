-- sfcc.nvim: resolve SFCC cartridge require paths like require('*/cartridge/...')
local M = {}

local cache = {} -- cwd -> { roots = {dir,...} }

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
local function cartridge_roots(cwd)
  local hit = cache[cwd]
  if hit then
    return hit
  end
  local roots = walk(cwd, {})

  -- order by dw.json cartridgesPath ("app_custom:app_storefront_base") when present
  local order = read_cartridges_path(cwd)
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
  cache[cwd] = roots
  return roots
end

local function existing_file(base)
  for _, ext in ipairs { '', '.js', '.ds', '.json' } do
    if vim.fn.filereadable(base .. ext) == 1 then
      return base .. ext
    end
  end
end

--- Resolve a require spec to existing files, in cartridge-path order.
---@param spec string e.g. "*/cartridge/scripts/util" or "~/cartridge/models/cart"
---@param file string buffer file path (used for "~")
---@return string[]
function M.resolve(spec, file)
  local rest = spec:match('^%*/(.+)') or spec:match('^~/(.+)')
  if not rest then
    return {}
  end
  local roots
  if spec:sub(1, 1) == '~' then
    roots = { vim.fs.root(file, 'cartridge') }
  else
    roots = cartridge_roots(vim.fn.getcwd())
  end
  local found = {}
  for _, root in ipairs(roots) do
    local hit = existing_file(root .. '/' .. rest)
    if hit then
      table.insert(found, hit)
    end
  end
  return found
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
  local found = spec and M.resolve(spec, vim.api.nvim_buf_get_name(0)) or {}
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
  if #found == 1 then
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
