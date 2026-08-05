if vim.g.loaded_meat_review then
  return
end
vim.g.loaded_meat_review = 1

vim.api.nvim_create_user_command('MeatReview', function()
  require('meat-review').open()
end, {})

vim.api.nvim_create_user_command('MeatReviewSubmit', function()
  require('meat-review').submit()
end, {})

vim.api.nvim_create_user_command('MeatReviewStatus', function()
  require('meat-review').status()
end, {})
