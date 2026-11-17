local M = {}

M.config = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

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
