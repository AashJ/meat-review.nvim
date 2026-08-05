local raw_diff = table.concat({
  'diff --git a/example.lua b/example.lua',
  'index 1111111..2222222 100644',
  '--- a/example.lua',
  '+++ b/example.lua',
  '@@ -1 +1 @@',
  '-old',
  '+new',
}, '\n')

local responses = {
  { stdout = '/tmp/example\n' },
  { stdout = '{"nameWithOwner":"owner/repo"}' },
  {
    stdout = vim.json.encode({
      number = 42,
      url = 'https://github.com/owner/repo/pull/42',
      title = 'Example PR',
      state = 'OPEN',
      baseRefName = 'release',
      headRefName = 'feature',
      headRefOid = 'abc123',
    }),
  },
  { stdout = raw_diff },
  { stdout = vim.json.encode({ summary = 'Small example.', elision = '0%', smart_diff = raw_diff }) },
}

local expected = {
  { 'git', 'rev-parse', '--show-toplevel' },
  { 'gh', 'repo', 'view', '--json', 'nameWithOwner' },
  { 'gh', 'pr', 'view', '--json', 'number,url,title,state,baseRefName,headRefName,headRefOid' },
  { 'gh', 'pr', 'diff', '42' },
  { 'meat', '-json' },
}

local calls, notifications, pending, pending_meat, scheduled = {}, {}, nil, nil, 0
vim.env.MEAT_OPENAI_API_KEY = 'plugin-scoped-test-key'
vim.env.OPENAI_API_KEY = nil
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
vim.schedule = function(callback)
  scheduled = scheduled + 1
  callback()
end
vim.system = function(args, options, callback)
  calls[#calls + 1] = { args = args, options = options }
  local response = responses[#calls]
  assert(response, 'unexpected external command')
  response.code, response.stderr = 0, ''
  if #calls == 1 then
    pending = function()
      callback(response)
    end
  elseif #calls == 5 then
    pending_meat = function()
      callback(response)
    end
  else
    callback(response)
  end
  return {}
end

local review = require('meat-review')
local original_buf = vim.api.nvim_get_current_buf()

local function mapping(buf, mode, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if item.lhs == lhs then
      assert(type(item.callback) == 'function', lhs .. ' must use a Lua callback')
      return item.callback
    end
  end
  error(('missing %s mapping for %s'):format(mode, lhs))
end

review.open()
assert(notifications[1] == 'Starting Meat review…')
assert(#calls == 1, 'start should return while repository discovery is pending')

review.status()
assert(notifications[#notifications]:match('Meat review: Resolving repository'))

review.open()
assert(notifications[#notifications] == 'Meat review is still running…')
assert(#calls == 1, 'a running review must not start another process')

pending()
assert(#calls == 5, 'the successful workflow should issue five commands')
review.status()
assert(notifications[#notifications]:match('Meat review: Running Meat'))
assert(vim.api.nvim_get_current_buf() == original_buf, 'running Meat must not open a review buffer')

pending_meat()
assert(vim.api.nvim_get_current_buf() == original_buf, 'ready reviews must not open automatically')
assert(notifications[#notifications]:match('ready for PR #42'), 'ready notification is missing')
assert(calls[5].options.stdin == raw_diff, 'Meat must receive the exact GitHub diff bytes')
assert(calls[5].options.env.OPENAI_API_KEY == 'plugin-scoped-test-key', 'Meat must receive the plugin-scoped API key')
assert(vim.env.OPENAI_API_KEY == nil, 'the plugin-scoped key must not become a general Neovim environment variable')

for index, command in ipairs(expected) do
  assert(
    vim.deep_equal(calls[index].args, command),
    ('command %d did not use the expected argument array'):format(index)
  )
end
assert(scheduled == 5, 'every process callback must enter vim.schedule')

review.open()
local review_buf = vim.api.nvim_get_current_buf()
assert(review_buf ~= original_buf, 'the second ready invocation should open the review')
assert(vim.bo[review_buf].buftype == 'nofile')
assert(vim.bo[review_buf].bufhidden == 'wipe')
assert(vim.bo[review_buf].swapfile == false)
assert(vim.bo[review_buf].modifiable == false)
assert(vim.api.nvim_buf_get_lines(review_buf, 0, 1, false)[1] == '── example.lua ──')

review.open()
assert(vim.api.nvim_get_current_buf() == review_buf, 'an open review should be focused instead of duplicated')

local changed_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(review_buf, 0, -1, false)) do
  if line == '+new' then
    changed_line = index
  end
end
assert(changed_line, 'mapped addition is missing from the review')
vim.api.nvim_win_set_cursor(0, { changed_line, 0 })
mapping(review_buf, 'n', 'a')()

local editor_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[editor_buf].filetype == 'markdown', 'comment editor should be Markdown')
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { 'First line.', 'Second line.' })
vim.cmd('write')

local namespaces = vim.api.nvim_get_namespaces()
local marks = vim.api.nvim_buf_get_extmarks(review_buf, namespaces['meat-review-comments'], 0, -1, { details = true })
assert(#marks == 1, 'saving should add one visible draft annotation')
assert(
  marks[1][4].sign_text and marks[1][4].sign_text:find('●', 1, true),
  'draft annotation should include a visible sign'
)
assert(vim.inspect(marks[1][4].virt_lines):find('Draft comment', 1, true), 'draft annotation should have a quiet label')
assert(vim.inspect(marks[1][4].virt_lines):find('MeatReviewDraftText', 1, true), 'draft body should use readable text')

mapping(review_buf, 'n', 'S')()
local preview_buf = vim.api.nvim_get_current_buf()
local preview_win = vim.api.nvim_get_current_win()
assert(vim.api.nvim_win_get_config(preview_win).relative == 'win', 'submission editor must float over the review')
assert(vim.api.nvim_win_get_buf(vim.api.nvim_win_get_config(preview_win).win) == review_buf)
assert(vim.bo[preview_buf].modifiable == true, 'submission editor must be editable')
assert(vim.bo[preview_buf].buftype == 'acwrite', 'submission editor must support intercepted writes')
local preview_marks =
  vim.api.nvim_buf_get_extmarks(preview_buf, namespaces['meat-review-preview'], 0, -1, { details = true })
local preview_virtual = vim.inspect(preview_marks)
assert(
  preview_virtual:find('example.lua', 1, true)
    and preview_virtual:find('RIGHT', 1, true)
    and preview_virtual:find('First line.', 1, true),
  'inline comments must remain visible in the submission editor'
)
assert(#calls == 5, 'opening a preview must not contact GitHub')

vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { 'Overall summary', '', 'Longer review description.' })
vim.cmd('write')
mapping(preview_buf, 'n', '3')()
preview_marks = vim.api.nvim_buf_get_extmarks(preview_buf, namespaces['meat-review-preview'], 0, -1, { details = true })
assert(
  vim.inspect(preview_marks):find('● [3] Request changes', 1, true),
  'selected action should look like a radio choice'
)

local confirmation_seen = false
vim.ui.select = function(_, options, callback)
  confirmation_seen = options.prompt == 'Submit Request changes review to GitHub?'
  callback('Cancel')
end
mapping(preview_buf, 'n', 'S')()
assert(confirmation_seen, 'preview confirmation must lead to a separate explicit prompt')
assert(#calls == 5, 'cancelling final confirmation must not contact GitHub')

mapping(preview_buf, 'n', 'q')()
mapping(review_buf, 'n', 'S')()
local saved_preview_buf = vim.api.nvim_get_current_buf()
assert(
  table
    .concat(vim.api.nvim_buf_get_lines(saved_preview_buf, 0, -1, false), '\n')
    :find('Longer review description.', 1, true),
  'the top-level review draft should survive cancelling the submission editor'
)
mapping(saved_preview_buf, 'n', 'D')()
assert(notifications[#notifications] == 'Top-level review draft discarded; inline comments were kept.')

vim.api.nvim_buf_delete(review_buf, { force = true })
review.open()
local reopened_buf = vim.api.nvim_get_current_buf()
local reopened_marks =
  vim.api.nvim_buf_get_extmarks(reopened_buf, namespaces['meat-review-comments'], 0, -1, { details = true })
assert(#reopened_marks == 1, 'drafts should survive closing and reopening the review buffer')

print('flow test passed')
