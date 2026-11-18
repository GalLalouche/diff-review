if vim.g.loaded_diff_review then
  return
end
vim.g.loaded_diff_review = true

-- lazy.nvim sources this file and then calls setup(opts). Defer the default
-- so a lazy configuration is the one that runs.
vim.schedule(function()
  local diff_review = require("diff-review")
  if not diff_review.did_setup then
    diff_review.setup()
  end
end)
