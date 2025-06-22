return {
    "sindrets/diffview.nvim",
    cmd = {
        "DiffviewOpen",
        "DiffviewClose",
        "DiffviewToggleFiles",
        "DiffviewFocusFiles",
        "DiffviewRefresh",
        "DiffviewFileHistory"
    },
    keys = {
        { "<leader>do", "<cmd>DiffviewOpen<cr>",        desc = "Open Diffview" },
        { "<leader>dc", "<cmd>DiffviewClose<cr>",       desc = "Close Diffview" },
        { "<leader>dh", "<cmd>DiffviewFileHistory<cr>", desc = "File History" },
        { "<leader>df", "<cmd>DiffviewToggleFiles<cr>", desc = "Toggle Files Panel" },
    },
}
