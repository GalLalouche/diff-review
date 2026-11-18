local M = {}

M.defaults = {
  keymaps = {
    goto_link = "gd",
    next_file = "]f",
    prev_file = "[f",
    next_action_item = "]a",
    prev_action_item = "[a",
  },
}

M.config = vim.deepcopy(M.defaults)
M.did_setup = false

function M.setup(opts)
  M.did_setup = true
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  vim.filetype.add({
    extension = {
      answer = "diff",
    },
  })

  local sticky = require("diff-review.sticky")
  sticky.setup()

  local links = require("diff-review.links")
  links.setup(M.config)

  vim.api.nvim_create_user_command("DiffReview", function()
    local state = sticky.toggle() and "enabled" or "disabled"
    vim.notify("diff-review sticky header " .. state, vim.log.levels.INFO)
  end, {})
end

return M
