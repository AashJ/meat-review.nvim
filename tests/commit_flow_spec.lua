local raw_diff = table.concat({
  'diff --git a/example.lua b/example.lua',
  'index 1111111..2222222 100644',
  '--- a/example.lua',
  '+++ b/example.lua',
  '@@ -1 +1 @@',
  '-old',
  '+new',
}, '\n')

local current = { sha = 'head123', parent = 'base123', title = 'Example commit' }
local calls, notifications, meat_calls = {}, {}, 0
local pr_base = 'prbase123'
local pr_head
local submitted_payload
local submitted_endpoint
local submission_error

vim.notify = function(message)
  notifications[#notifications + 1] = message
end
vim.schedule = function(callback)
  callback()
end
vim.system = function(args, options, callback)
  calls[#calls + 1] = { args = args, options = options }
  local response
  if vim.deep_equal(args, { 'git', 'rev-parse', '--show-toplevel' }) then
    response = { stdout = '/tmp/example\n' }
  elseif vim.deep_equal(args, { 'git', 'show', '-s', '--format=%H%n%P%n%s', 'HEAD' }) then
    response = {
      stdout = ('%s\n%s\n%s\n'):format(current.sha, current.parent or '', current.title),
    }
  elseif vim.deep_equal(args, { 'gh', 'repo', 'view', '--json', 'nameWithOwner' }) then
    response = { stdout = '{"nameWithOwner":"owner/fork"}' }
  elseif args[1] == 'gh' and args[2] == 'pr' and args[3] == 'view' then
    response = {
      stdout = vim.json.encode({
        number = 42,
        url = 'https://github.com/owner/repo/pull/42',
        title = 'Commit review PR',
        state = 'OPEN',
        baseRefName = 'main',
        baseRefOid = pr_base,
        headRefName = 'feature',
        headRefOid = pr_head or current.sha,
      }),
    }
  elseif args[1] == 'gh' and args[2] == 'pr' and args[3] == 'diff' then
    response = { stdout = raw_diff }
  elseif args[1] == 'git' and args[2] == 'diff' then
    assert(args[4] == current.parent and args[5] == current.sha, 'commit diff must use immutable parent/head SHAs')
    response = { stdout = raw_diff }
  elseif args[1] == 'git' and args[2] == 'show' and args[3] == '--format=' then
    assert(current.parent == nil and args[#args] == current.sha, 'root commit diff must use git show --root')
    response = { stdout = raw_diff }
  elseif vim.deep_equal(args, { 'meat', '-json' }) then
    meat_calls = meat_calls + 1
    response = { stdout = vim.json.encode({ summary = 'Local commit.', elision = '0%', smart_diff = raw_diff }) }
  elseif args[1] == 'gh' and args[2] == 'api' then
    submitted_payload = vim.json.decode(options.stdin)
    submitted_endpoint = args[5]
    if submission_error then
      response = {
        code = 1,
        stderr = 'gh: Validation Failed (HTTP 422)',
        stdout = vim.json.encode({ message = submission_error }),
      }
    else
      response = { stdout = '{"html_url":"https://github.com/owner/repo/pull/42#pullrequestreview-1"}' }
    end
  end
  assert(response, 'unexpected external command: ' .. vim.inspect(args))
  response.code = response.code or 0
  response.stderr = response.stderr or ''
  callback(response)
  return {}
end

local function mapping(buf, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if item.lhs == lhs then
      return item.callback
    end
  end
  error('missing mapping for ' .. lhs)
end

vim.cmd('runtime plugin/meat-review.lua')
assert(vim.fn.exists(':MeatReviewCommit') == 2, 'the local commit command must be registered')
assert(vim.fn.exists(':MeatReviewOpenFile') == 2, 'the file opener command must be registered')

local review = require('meat-review')
local original_buf = vim.api.nvim_get_current_buf()
review.open_commit()
assert(vim.api.nvim_get_current_buf() == original_buf, 'generating a commit review must not open it automatically')
assert(notifications[#notifications]:match('ready for commit head123'))
assert(meat_calls == 1)

review.open_commit()
local review_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(review_buf):match('commit head123'), 'the commit review buffer must identify its SHA')
assert(meat_calls == 1, 'opening an exact cached commit must not rerun Meat')

local changed_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(review_buf, 0, -1, false)) do
  if line == '+new' then
    changed_line = index
  end
end
vim.api.nvim_win_set_cursor(0, { changed_line, 0 })
local calls_before_open = #calls
mapping(review_buf, 'o')()
local file_buf = vim.api.nvim_get_current_buf()
assert(file_buf ~= review_buf and vim.bo[file_buf].filetype == 'diff')
assert(vim.api.nvim_buf_get_lines(file_buf, 0, 1, false)[1] == 'diff --git a/example.lua b/example.lua')
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, 'the default file opener must use a separate pane')
assert(#calls == calls_before_open, 'the default file opener must reuse the captured full diff')
mapping(file_buf, 'q')()

local opened_context
review.setup({
  open_file = function(context)
    opened_context = context
  end,
})
mapping(review_buf, 'o')()
assert(opened_context.kind == 'commit' and opened_context.path == 'example.lua')
assert(opened_context.base_sha == 'base123' and opened_context.head_sha == 'head123')
assert(opened_context.line == 1 and opened_context.side == 'RIGHT')

local calls_before_submit = #calls
mapping(review_buf, 'a')()
local editor_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { 'Commit-scoped comment.' })
vim.cmd('write')
mapping(review_buf, 'S')()
local preview_buf = vim.api.nvim_get_current_buf()
assert(preview_buf ~= review_buf, 'commit-scoped reviews must open the normal submission preview')
assert(#calls == calls_before_submit, 'opening commit submission preview must not contact GitHub')
vim.ui.select = function(items, _, callback)
  callback(items[2])
end
mapping(preview_buf, 'S')()
assert(submitted_payload.commit_id == current.sha, 'commit review submission must target the PR head')
assert(#submitted_payload.comments == 1 and submitted_payload.comments[1].line == 1)
assert(submitted_endpoint == 'repos/owner/repo/pulls/42/reviews', 'submission must target the PR base repository')
assert(notifications[#notifications]:match('GitHub review submitted'))

vim.api.nvim_set_current_buf(review_buf)
vim.api.nvim_win_set_cursor(0, { changed_line, 0 })
mapping(review_buf, 'a')()
editor_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { 'Try again.' })
vim.cmd('write')
mapping(review_buf, 'S')()
preview_buf = vim.api.nvim_get_current_buf()
submission_error = 'Pull request review thread line must be part of the diff'
mapping(preview_buf, 'S')()
assert(
  notifications[#notifications]:find(submission_error, 1, true),
  'GitHub JSON error details must be shown with the HTTP status'
)
submission_error = nil

current = { sha = 'head456', parent = 'head123', title = 'Next commit' }
review.open_commit()
assert(notifications[#notifications]:match('ready for commit head456'))
assert(meat_calls == 2, 'a new HEAD must create a fresh local review')

current = { sha = 'root123', parent = nil, title = 'Root commit' }
review.open_commit()
assert(notifications[#notifications]:match('ready for commit root123'))
assert(meat_calls == 3, 'a root commit must be reviewable')

pr_head = 'remote-head'
review.open_commit()
assert(notifications[#notifications] == 'Local HEAD does not match the current pull request head')
assert(meat_calls == 3, 'a mismatched local HEAD must not be sent to Meat')

print('commit flow test passed')
