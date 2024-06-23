return {
    {
        'junegunn/fzf',
        build = function()
            vim.fn['fzf#install']()
        end
    },
    {
        'junegunn/fzf.vim',
        dependencies = { 'junegunn/fzf' },
        config = function()
            -- FZF の色設定
            vim.env.FZF_DEFAULT_OPTS = '--color=fg:#c0caf5,bg:#1a1b26,hl:#bb9af7 ' ..
                '--color=fg+:#c0caf5,bg+:#1a1b26,hl+:#7dcfff ' ..
                '--color=info:#7aa2f7,prompt:#7dcfff,pointer:#7dcfff ' ..
                '--color=marker:#9ece6a,spinner:#9ece6a,header:#9ece6a'

            -- キーマッピング
            vim.keymap.set('n', '<leader>ff', ':Files<CR>', { noremap = true, silent = true })
            vim.keymap.set('n', '<leader>fg', ':Rg<CR>', { noremap = true, silent = true })
            vim.keymap.set('n', '<leader>fb', ':Buffers<CR>', { noremap = true, silent = true })
            vim.keymap.set('n', '<leader>fh', ':History<CR>', { noremap = true, silent = true })

            -- FZF のウィンドウ位置とサイズ
            vim.g.fzf_layout = {
                window = {
                    width = 0.9,
                    height = 0.8,
                    highlight = 'Comment',
                }
            }

            -- プレビューウィンドウの設定
            vim.env.FZF_DEFAULT_OPTS = vim.env.FZF_DEFAULT_OPTS ..
            ' --preview "bat --style=numbers --color=always --line-range :500 {}"'

            -- Rg コマンドのカスタマイズ（ファイル名を含める）
            vim.cmd([[
        command! -bang -nargs=* Rg
          \ call fzf#vim#grep(
          \   'rg --column --line-number --no-heading --color=always --smart-case -- '.shellescape(<q-args>), 1,
          \   fzf#vim#with_preview({'options': '--delimiter : --nth 4..'}), <bang>0)
      ]])

            -- Git ファイルのみを検索
            vim.keymap.set('n', '<leader>fG', ':GFiles<CR>', { noremap = true, silent = true })

            -- ヘルプタグの検索
            vim.keymap.set('n', '<leader>fH', ':Helptags<CR>', { noremap = true, silent = true })

            -- マークの検索
            vim.keymap.set('n', '<leader>fm', ':Marks<CR>', { noremap = true, silent = true })
        end
    }
}
