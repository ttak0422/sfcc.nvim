-- The configuration/mapping part of TypeScript resolution, without a Node or
-- language-server dependency. File probing stays in sfcc's Prophet resolver.
local M = {}
local cache = {}

local function valid_path(path)
  return type(path) == 'string' and not path:find('%z')
end

local function absolute(path)
  return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil
end

local function join(dir, path)
  -- TypeScript accepts Windows separators on every OS. Do not expand $VARS/~
  -- or collapse symlink/.. components.
  path = path:gsub('\\', '/')
  return absolute(path) and path or dir .. '/' .. path
end

local function substitute_config_dir(path, dir)
  path = path:gsub('\\', '/')
  return (path:gsub('^%${configDir}/?', function() return dir .. '/' end))
end

local function read(path)
  local f = io.open(path)
  if not f then
    return nil, 'cannot read ' .. path
  end
  local text = f:read('*a')
  f:close()
  return text
end

-- Tokenize JSONC so comment markers and trailing-comma-like text inside
-- strings survive unchanged. vim.json.decode still validates the JSON.
local function decode(text)
  text = text:gsub('^\239\187\191', '')
  local tokens, i = {}, 1
  while i <= #text do
    local ch, next_ch = text:sub(i, i), text:sub(i + 1, i + 1)
    if ch == '"' then
      local start = i
      i = i + 1
      while i <= #text do
        local c = text:sub(i, i)
        i = i + (c == '\\' and 2 or 1)
        if c == '"' then
          break
        end
      end
      table.insert(tokens, text:sub(start, i - 1))
    elseif ch == '/' and next_ch == '/' then
      i = text:find('[\r\n]', i + 2) or (#text + 1)
    elseif ch == '/' and next_ch == '*' then
      local finish = text:find('*/', i + 2, true)
      if not finish then
        return nil, 'unterminated block comment'
      end
      i = finish + 2
    elseif ch:match('%s') then
      i = i + 1
    elseif ch:match('[{}%[%]:,]') then
      table.insert(tokens, ch)
      i = i + 1
    else
      local start = i
      repeat
        i = i + 1
        ch = text:sub(i, i)
      until i > #text or ch:match('[%s{}%[%]:,"/]')
      table.insert(tokens, text:sub(start, i - 1))
    end
  end

  local clean = {}
  for n, token in ipairs(tokens) do
    if token ~= ',' or (tokens[n + 1] ~= '}' and tokens[n + 1] ~= ']') then
      table.insert(clean, token)
    end
  end
  local ok, json = pcall(vim.json.decode, table.concat(clean, ' '))
  if not ok or type(json) ~= 'table' or tokens[1] ~= '{' then
    return nil, 'invalid JSONC object'
  end

  -- Lua hash iteration loses declaration order. Keep it for wildcard patterns
  -- with equal-length prefixes, whose first declaration wins in TypeScript.
  local stack, key, order, seen = {}, nil, {}, {}
  for n, token in ipairs(tokens) do
    if token:sub(1, 1) == '"' and tokens[n + 1] == ':' then
      key = vim.json.decode(token)
      if #stack == 3 and stack[2] == 'compilerOptions' and stack[3] == 'paths' and not seen[key] then
        table.insert(order, key)
        seen[key] = true
      end
    elseif token == '{' or token == '[' then
      if #stack == 2 and stack[2] == 'compilerOptions' and key == 'paths' then
        -- Duplicate object properties use the last value, as JSON.decode does.
        order, seen = {}, {}
      end
      table.insert(stack, key or '')
      key = nil
    elseif token == '}' or token == ']' then
      table.remove(stack)
    elseif token == ',' then
      key = nil
    end
  end
  return json, nil, order
end

local function config_file(path)
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  if not path:match('%.json$') and vim.fn.filereadable(path .. '.json') == 1 then
    return path .. '.json'
  end
end

local function extended_file(name, dir)
  name = name:gsub('\\', '/')
  if absolute(name) or name:match('^%.%.?[/\\]') then
    return config_file(join(dir, name))
  end
  -- Node-style package lookup (including scoped packages and config subpaths).
  while dir do
    local path = dir .. '/node_modules/' .. name
    local hit = config_file(path)
    if hit then
      return hit
    end
    local text = read(path .. '/package.json')
    local ok, pkg = pcall(vim.json.decode, text or '')
    if ok and type(pkg) == 'table' and valid_path(pkg.tsconfig) then
      hit = config_file(join(path, pkg.tsconfig))
    end
    hit = hit or config_file(path .. '/tsconfig.json')
    if hit then
      return hit
    end
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
end

local function load(path, active, errors, depth)
  local id = vim.uv.fs_realpath(path) or path
  if active[id] or depth > 64 then
    table.insert(errors, 'circular or excessively deep extends: ' .. path)
    return {}
  end
  local text, err = read(path)
  local json, order
  if text then
    json, err, order = decode(text)
  end
  if not json then
    table.insert(errors, path .. ': ' .. (err or 'invalid config'))
    return {}
  end
  active[id] = true
  local dir, result = vim.fs.dirname(path), {}
  local bases = type(json.extends) == 'string' and { json.extends } or json.extends
  if bases ~= nil then
    if type(bases) ~= 'table' or not vim.islist(bases) then
      table.insert(errors, path .. ': extends must be a string or array')
    else
      for _, name in ipairs(bases) do
        local base = valid_path(name) and extended_file(name, dir)
        if base then
          for k, value in pairs(load(base, active, errors, depth + 1)) do
            result[k] = value
          end
        else
          table.insert(errors, path .. ': cannot resolve extends ' .. tostring(name):gsub('%z', '\\0'))
        end
      end
    end
  end
  local opts = json.compilerOptions
  if type(opts) == 'table' then
    if valid_path(opts.baseUrl) then
      -- ${configDir} is relative to the final consumer, not this base config.
      result.base_url = opts.baseUrl:match('^%${configDir}') and opts.baseUrl or join(dir, opts.baseUrl)
    elseif opts.baseUrl ~= nil then
      table.insert(errors, path .. ': baseUrl must be a string without NUL bytes')
    end
    if opts.paths ~= nil then
      -- paths replaces the whole inherited map, it does not merge aliases.
      result.paths, result.paths_dir, result.order = {}, dir, order
      if type(opts.paths) ~= 'table' or vim.islist(opts.paths) and next(opts.paths) ~= nil then
        table.insert(errors, path .. ': paths must be an object')
      else
        for _, key in ipairs(order) do
          local targets = opts.paths[key]
          local _, stars = key:gsub('%*', '')
          if stars > 1 or key:find('%z') or type(targets) ~= 'table' or not vim.islist(targets) or #targets == 0 then
            table.insert(errors, path .. ': invalid paths entry ' .. key:gsub('%z', '\\0'))
          else
            result.paths[key] = {}
            for _, target in ipairs(targets) do
              local count = valid_path(target) and select(2, target:gsub('%*', '')) or 2
              if count <= 1 then
                table.insert(result.paths[key], target)
              else
                table.insert(errors, path .. ': invalid target for ' .. key)
              end
            end
          end
        end
      end
    end
  end
  active[id] = nil
  return result
end

function M.info(file, uncached)
  local start = file ~= '' and vim.fs.dirname(file) or assert(vim.uv.cwd())
  local dir = vim.fs.root(start, 'tsconfig.json')
  if not dir then
    return nil
  end
  local path = dir .. '/tsconfig.json'
  if uncached or not cache[path] then
    local errors = {}
    local config = load(path, {}, errors, 1)
    config.file, config.errors = path, errors
    if config.base_url then
      config.base_url = substitute_config_dir(config.base_url, dir)
    end
    if uncached then
      return config
    end
    cache[path] = config
  end
  return cache[path]
end

function M.resolve(spec, file, existing_file)
  -- Only explicit path mappings opt other projects into this resolver. Do not
  -- intercept relative imports or non-script buffers with a global gf map.
  if spec:match('^%.%.?/') or spec:find('[%c]') or spec:match('^%a[%w+.-]*://') then
    return nil
  end
  if file ~= '' and not (file:match('%.[cm]?[jt]sx?$') or file:match('%.ds$') or file:match('%.isml$')) then
    return nil
  end
  local config = M.info(file)
  if not config or not config.paths then
    return nil
  end
  local key, capture, length = nil, nil, -1
  if config.paths[spec] then
    key = spec
  else
    for _, pattern in ipairs(config.order) do
      local star = pattern:find('*', 1, true)
      if star and config.paths[pattern] then
        local prefix, suffix = pattern:sub(1, star - 1), pattern:sub(star + 1)
        if #prefix > length and #spec >= #prefix + #suffix
          and spec:sub(1, #prefix) == prefix and (#suffix == 0 or spec:sub(-#suffix) == suffix) then
          key, capture, length = pattern, spec:sub(#prefix + 1, #spec - #suffix), #prefix
        end
      end
    end
  end
  if key then
    for _, target in ipairs(config.paths[key]) do
      target = substitute_config_dir(target, vim.fs.dirname(config.file))
      if capture ~= nil then
        target = target:gsub('%*', function() return capture end)
      end
      local hit = existing_file(join(config.base_url or config.paths_dir, target))
      if hit then
        return hit
      end
    end
  end
end

function M.reset()
  cache = {}
end

return M
