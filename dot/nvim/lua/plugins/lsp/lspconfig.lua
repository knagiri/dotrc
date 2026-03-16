return {
    "neovim/nvim-lspconfig",
    dependencies = {
        "williamboman/mason.nvim",
        "williamboman/mason-lspconfig.nvim",
        "saghen/blink.cmp",
    },
    config = function()
        local capabilities = require('blink.cmp').get_lsp_capabilities()

        -- Mason.nvim の設定
        require("mason").setup()
        require("mason-lspconfig").setup({
            ensure_installed = {
                "lua_ls", "pyright", "ts_ls", "rust_analyzer", "gopls",
                "clangd", "jsonls", "yamlls", "dockerls", "bashls",
                "copilot",
            },
            automatic_installation = true,
        })

        -- 各言語サーバーの設定
        local servers = {
            lua_ls = {},
            pyright = {
                settings = {
                    python = {
                        analysis = {
                            typeCheckingMode = "basic",
                            autoSearchPaths = true,
                            useLibraryCodeForTypes = true,
                        }
                    }
                }
            },
            ts_ls = {},
            gopls = {},
            clangd = {},
            jsonls = {},
            yamlls = {},
            dockerls = {},
            bashls = {},
            copilot = {},
            rust_analyzer = {
                settings = {
                    ['rust-analyzer'] = {
                        checkOnSave = {
                            command = "clippy",
                        },
                        procMacro = {
                            enable = true,
                            ignored = {
                                ['async-trait'] = { "async_trait" },
                                ['napi-derive'] = { "napi" },
                                ['async-recursion'] = { "async_recursion" },
                            },
                        },
                    }
                }
            }
        }

        for server_name, config in pairs(servers) do
            config.capabilities = capabilities
            vim.lsp.config(server_name, config)
        end

        -- 自動的に有効化
        vim.api.nvim_create_autocmd("FileType", {
            callback = function(args)
                for server_name, _ in pairs(servers) do
                    vim.lsp.enable(server_name)
                end
            end,
        })

        -- キーマッピング
        vim.api.nvim_create_autocmd('LspAttach', {
            group = vim.api.nvim_create_augroup('UserLspConfig', {}),
            callback = function(ev)
                local opts = { buffer = ev.buf }
                vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
                vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
                vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
                vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
                vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, opts)
                vim.keymap.set('n', '<space>wa', vim.lsp.buf.add_workspace_folder, opts)
                vim.keymap.set('n', '<space>wr', vim.lsp.buf.remove_workspace_folder, opts)
                vim.keymap.set('n', '<space>wl', function()
                    print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
                end, opts)
                vim.keymap.set('n', '<space>D', vim.lsp.buf.type_definition, opts)
                vim.keymap.set('n', '<space>rn', vim.lsp.buf.rename, opts)
                vim.keymap.set({ 'n', 'v' }, '<space>ca', vim.lsp.buf.code_action, opts)
                vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
                vim.keymap.set('n', '<space>lf', function()
                    vim.lsp.buf.format { async = true }
                end, opts)
            end,
        })
    end,
}
