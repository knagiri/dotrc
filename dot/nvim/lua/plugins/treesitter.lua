return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter-textobjects",
    },
    config = function()
      require("nvim-treesitter.configs").setup({
        -- 自動インストールする言語パーサーを指定
        ensure_installed = {
          "lua", "vim", "vimdoc", "query",
          "python", "javascript", "typescript", "tsx",
          "html", "css", "json", "yaml", "toml",
          "rust", "go", "c", "cpp",
          "bash", "markdown", "markdown_inline",
        },

        -- 同期インストールを有効化
        sync_install = false,

        -- 自動タグを有効化
        auto_install = true,

        -- ハイライトを有効化
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },

        -- インデントを有効化
        indent = { enable = true },

        -- インクリメンタル選択を有効化
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "<C-space>",
            node_incremental = "<C-space>",
            scope_incremental = false,
            node_decremental = "<bs>",
          },
        },

        -- テキストオブジェクトを有効化
        textobjects = {
          select = {
            enable = true,
            lookahead = true,
            keymaps = {
              ["af"] = "@function.outer",
              ["if"] = "@function.inner",
              ["ac"] = "@class.outer",
              ["ic"] = "@class.inner",
            },
          },
          move = {
            enable = true,
            set_jumps = true,
            goto_next_start = {
              ["]m"] = "@function.outer",
              ["]]"] = "@class.outer",
            },
            goto_next_end = {
              ["]M"] = "@function.outer",
              ["]["] = "@class.outer",
            },
            goto_previous_start = {
              ["[m"] = "@function.outer",
              ["[["] = "@class.outer",
            },
            goto_previous_end = {
              ["[M"] = "@function.outer",
              ["[]"] = "@class.outer",
            },
          },
        },
      })
    end,
  },
}
