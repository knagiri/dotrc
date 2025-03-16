local function load_secret_file()
    local home = os.getenv("HOME")
    local secret_file = home .. "/.anthropic/nvim.secret"

    -- ファイルが存在するか確認
    local file = io.open(secret_file, "r")
    if not file then
        print("Warning: Secret file not found: " .. secret_file)
        return nil
    end

    -- ファイルの内容を読み込む
    local content = file:read("*all")
    file:close()

    -- 改行コードを削除して返す
    return string.gsub(content, "^%s*(.-)%s*$", "%1")
end

-- 起動時に秘密情報を読み込み、環境変数として設定
local function setup_api_key()
    local api_key = load_secret_file()
    if api_key then
        -- 環境変数を設定
        vim.env.ANTHROPIC_API_KEY = api_key
        print("ANTHROPIC_API_KEY has been set")
    end
end

-- NeoVim起動時に実行
setup_api_key()

return {
    "yetone/avante.nvim",
    event = "VeryLazy",
    version = false, -- Set this to "*" to always pull the latest release version, or set it to false to update to the latest code changes.
    opts = {
        -- add any opts here
        -- for example
        provider = "claude",
        claude = {
            endpoint = "https://api.anthropic.com",
            model = "claude-3-7-sonnet-20250219", -- your desired model (or use gpt-4o, etc.)
            timeout = 30000,                      -- timeout in milliseconds
            temperature = 0,                      -- adjust if needed
            max_tokens = 4096,
            -- reasoning_effort = "high"          -- only supported for reasoning models (o1, etc.)
        },
    },
    -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`
    build = "make",
    -- build = "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false" -- for windows
    dependencies = {
        "nvim-treesitter/nvim-treesitter",
        "stevearc/dressing.nvim",
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        --- The below dependencies are optional,
        "echasnovski/mini.pick",         -- for file_selector provider mini.pick
        "nvim-telescope/telescope.nvim", -- for file_selector provider telescope
        "hrsh7th/nvim-cmp",              -- autocompletion for avante commands and mentions
        "ibhagwan/fzf-lua",              -- for file_selector provider fzf
        "nvim-tree/nvim-web-devicons",   -- or echasnovski/mini.icons
        "zbirenbaum/copilot.lua",        -- for providers='copilot'
        {
            -- support for image pasting
            "HakonHarnes/img-clip.nvim",
            event = "VeryLazy",
            opts = {
                -- recommended settings
                default = {
                    embed_image_as_base64 = false,
                    prompt_for_file_name = false,
                    drag_and_drop = {
                        insert_mode = true,
                    },
                    -- required for Windows users
                    use_absolute_path = true,
                },
            },
        },
        {
            -- Make sure to set this up properly if you have lazy=true
            'MeanderingProgrammer/render-markdown.nvim',
            opts = {
                file_types = { "markdown", "Avante" },
            },
            ft = { "markdown", "Avante" },
        },
    },
}
