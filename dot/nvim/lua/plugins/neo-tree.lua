return {
  -- NeoTree: https://github.com/nvim-neo-tree/neo-tree.nvim
  {
      "nvim-neo-tree/neo-tree.nvim",
      branch = "v3.x",
      keys = {
        { "<leader>ft", "<cmd>Neotree toggle<cr>", desc = "NeoTree" },
      },
      config = function()
        require("neo-tree").setup()
      end,
      dependencies = {
        "nvim-lua/plenary.nvim",
        "nvim-tree/nvim-web-devicons", -- not strictly required, but recommended
        "MunifTanjim/nui.nvim",
        -- "3rd/image.nvim", -- Optional image support in preview window: See `# Preview Mode` for more information
      }
  }
}
