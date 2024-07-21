return {
  "github/copilot.vim",
  event = "InsertEnter",
  config = function()
    vim.g.copilot_no_tab_map = true
    vim.g.copilot_assume_mapped = true
    vim.g.copilot_tab_fallback = ""

    vim.api.nvim_create_user_command("CopilotToggle", function()
      vim.g.copilot_enabled = not vim.g.copilot_enabled
      print("Copilot " .. (vim.g.copilot_enabled and "enabled" or "disabled"))
    end, {})

    -- キーマッピング
    vim.keymap.set("i", "<C-J>", 'copilot#Accept("<CR>")', {
      expr = true,
      replace_keycodes = false
    })
    vim.keymap.set("i", "<C-H>", '<Plug>(copilot-previous)')
    vim.keymap.set("i", "<C-L>", '<Plug>(copilot-next)')

    -- オプション: ファイルタイプごとの有効/無効設定
    vim.g.copilot_filetypes = {
      ["*"] = true,
      ["markdown"] = false,  -- Markdown では無効化
      ["text"] = false,      -- プレーンテキストでは無効化
    }

    -- オプション: Copilot のステータスをステータスラインに表示
    vim.o.statusline = vim.o.statusline .. "%{get(b:, 'copilot_enabled', v:false) ? '🤖' : ''}"
  end,
}
