return {
    "jackMort/ChatGPT.nvim",
    event = "VeryLazy",
    dependencies = {
        "MunifTanjim/nui.nvim",
        "nvim-lua/plenary.nvim",
        "nvim-telescope/telescope.nvim"
    },
    config = function()
        require("chatgpt").setup({
            api_key_cmd = "cat /home/nyagi/.openai/apikey",


            preferred_model = "gpt-4o", -- または "gpt-3.5-turbo" など

            -- Chat Options
            chat = {
                welcome_message = "ChatGPTへようこそ！どのようなお手伝いができますか？",
                loading_text = "Loading, please wait ...",
                question_sign = "🙂", -- プロンプトの前に表示される記号
                answer_sign = "🤖", -- 回答の前に表示される記号
                max_line_length = 120,
                sessions_window = {
                    border = {
                        style = "rounded",
                        text = {
                            top = " Sessions ",
                        },
                    },
                    win_options = {
                        winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
                    },
                },
            },

            -- キーマッピング
            keymaps = {
                close = { "<C-c>" },
                submit = "<C-Enter>",
                yank_last = "<C-y>",
                yank_last_code = "<C-k>",
                scroll_up = "<C-u>",
                scroll_down = "<C-d>",
                toggle_settings = "<C-o>",
                new_session = "<C-n>",
                cycle_windows = "<Tab>",
                -- 他のキーマッピングをカスタマイズできます
            },
        })

        -- コマンドのキーマッピング
        vim.keymap.set("n", "<leader>cc", ":ChatGPT<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>ce", ":ChatGPTEditWithInstruction<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>cg", ":ChatGPTRun grammar_correction<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>ct", ":ChatGPTRun translate<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>ck", ":ChatGPTRun keywords<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>cd", ":ChatGPTRun docstring<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>ca", ":ChatGPTRun add_tests<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>co", ":ChatGPTRun optimize_code<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>cs", ":ChatGPTRun summarize<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>cf", ":ChatGPTRun fix_bugs<CR>", { noremap = true, silent = true })
        vim.keymap.set("n", "<leader>cx", ":ChatGPTRun explain_code<CR>", { noremap = true, silent = true })
    end,
}
