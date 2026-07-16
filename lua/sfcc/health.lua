local M = {}

function M.check()
  local h = vim.health
  h.start('sfcc.nvim')
  local info = require('sfcc').info()

  h.info('workspace root: ' .. info.workspace)

  if not info.config then
    h.warn('no dw.json found — resolution is unordered, multiple hits go through vim.ui.select')
    return
  end
  h.ok('dw.json: ' .. info.config)

  if not info.order then
    local f = assert(io.open(info.config))
    local ok, err = pcall(vim.json.decode, f:read('*a'))
    f:close()
    if not ok then
      h.error('dw.json is not valid JSON (comments/trailing commas break vim.json.decode): ' .. err)
    else
      h.error('dw.json has neither a usable "cartridgesPath" string nor a "cartridge" array')
    end
    return
  end
  h.info('declared order: ' .. table.concat(info.order, ' : '))

  if #info.roots == 0 then
    h.warn('no cartridges found under the workspace root')
    return
  end

  local on_disk = {}
  for _, r in ipairs(info.roots) do
    on_disk[vim.fs.basename(r)] = true
  end
  local matched, missing = {}, {}
  for _, name in ipairs(info.order) do
    table.insert(on_disk[name] and matched or missing, name)
  end
  if #matched > 0 then
    h.ok(('%d/%d declared cartridges found on disk; */ resolves first-match in declared order'):format(#matched, #info.order))
  else
    h.error('no declared cartridge matches a folder on disk — resolution degrades to unordered vim.ui.select')
  end
  if #missing > 0 then
    h.warn('declared but not on disk: ' .. table.concat(missing, ', '))
  end

  local declared = {}
  for _, name in ipairs(info.order) do
    declared[name] = true
  end
  local unlisted, seen = {}, {}
  for _, r in ipairs(info.roots) do
    local name = vim.fs.basename(r)
    if not declared[name] and not seen[name] then
      seen[name] = true
      table.insert(unlisted, name)
    end
  end
  if #unlisted > 0 then
    h.info('on disk but not declared (excluded from */ resolution): ' .. table.concat(unlisted, ', '))
  end
end

return M
