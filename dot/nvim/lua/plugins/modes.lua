return {
    "mvllow/modes.nvim",
    tag = "v0.2.1",
    config = function()
        require('modes').setup({
            colors = {
                bg = "",             -- Optional bg param, defaults to Normal hl group
                copy = "#dbbc7f",    -- yellow
                delete = "#e67e80",  -- red
                insert = "#7fbbb3",  -- blue
                replace = "#e69875", -- orange
                visual = "#d699b6",  -- purple
            },

            -- Set opacity for cursorline and number background
            line_opacity = 0.35,
        })
    end
}
