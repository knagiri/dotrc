return {
    -- NeoTree: https://github.com/nvim-neo-tree/neo-tree.nvim
    {
        "nvim-neo-tree/neo-tree.nvim",
        branch = "v3.x",
        keys = {
            { "<leader>ft", "<cmd>Neotree toggle<cr>", desc = "NeoTree" },
        },
        config = function()
            require("neo-tree").setup({
                window = {
                    position = "top",
                    width = "100%",
                    height = "22%",
                },
                filesystem = {
                    filtered_items = {
                        visible = false,
                        hid_dotfiles = false,
                        hide_gitignored = true,
                    },
                    follow_current_file = {
                        enabled = true,
                        leave_dirs_open = false,
                    },
                    hijack_netrw_behavior = "open_current",
                    use_libuv_file_watcher = true,
                },
                event_handlers = {
                    {
                        event = "file_opened",
                        handler = function(file_path)
                            require("neo-tree.command").execute({ action = "close" })
                        end
                    },
                },
            })
        end,
        dependencies = {
            "nvim-lua/plenary.nvim",
            "nvim-tree/nvim-web-devicons", -- not strictly required, but recommended
            "MunifTanjim/nui.nvim",
            -- "3rd/image.nvim", -- Optional image support in preview window: See `# Preview Mode` for more information
        }
    }
}
