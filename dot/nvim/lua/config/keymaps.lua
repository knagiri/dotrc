vim.keymap.set("n", "j", "gj")
vim.keymap.set("n", "k", "gk")
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { noremap = true, silent = true })
vim.keymap.set('n', '<leader>E', vim.diagnostic.setloclist, { noremap = true, silent = true })
