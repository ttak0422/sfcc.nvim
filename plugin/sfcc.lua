if vim.g.loaded_sfcc then
  return
end
vim.g.loaded_sfcc = true

vim.api.nvim_create_user_command('SfccReset', function()
  require('sfcc').reset()
end, { desc = 'Reset sfcc.nvim cartridge cache' })
