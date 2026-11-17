if vim.g.loaded_diff_review then
  return
end
vim.g.loaded_diff_review = true

require("diff-review").setup()
