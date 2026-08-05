local M = {}

local diff = require('meat-review.diff')
local process = require('meat-review.process')
local sessions = require('meat-review.sessions')
local run = process.run
local decode = process.decode
local review_ns = vim.api.nvim_create_namespace('meat-review')
local comment_ns = vim.api.nvim_create_namespace('meat-review-comments')
local preview_ns = vim.api.nvim_create_namespace('meat-review-preview')

vim.api.nvim_set_hl(0, 'MeatReviewDraftRail', { default = true, link = 'Comment' })
vim.api.nvim_set_hl(0, 'MeatReviewDraftLabel', { default = true, link = 'DiagnosticInfo' })
vim.api.nvim_set_hl(0, 'MeatReviewDraftText', { default = true, link = 'Normal' })

local session = { state = 'idle', comments = {} }
local checking_identity = false
local config = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Meat Review' })
end

local function short_sha(sha)
  return sha:sub(1, 12)
end

local function session_label(target)
  if target.kind == 'commit' then
    return 'commit ' .. short_sha(target.commit.sha)
  end
  return ('PR #%d'):format(target.pr.number)
end

local function open_command(target)
  return target.kind == 'commit' and ':MeatReviewCommit' or ':MeatReview'
end

function M.setup(options)
  options = options or {}
  assert(type(options) == 'table', 'meat-review setup options must be a table')
  assert(options.open_file == nil or type(options.open_file) == 'function', 'open_file must be a function')
  config.open_file = options.open_file
end

local function fail_review(target, message)
  if session == target then
    session = { state = 'idle', comments = {} }
  end
  notify(message, vim.log.levels.ERROR)
end

local function comment_key(location)
  return table.concat({ location.path, location.side, tostring(location.line) }, '\0')
end

local function split_body(body)
  local lines = vim.split(body, '\n', { plain = true })
  return #lines > 0 and lines or { '' }
end

local function refresh_comments(target)
  if not target.buf or not vim.api.nvim_buf_is_valid(target.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(target.buf, comment_ns, 0, -1)
  for line, location in pairs(target.view.locations) do
    local draft = target.comments[comment_key(location)]
    if draft then
      local virtual = {
        { { '  │ ', 'MeatReviewDraftRail' }, { 'Draft comment', 'MeatReviewDraftLabel' } },
      }
      for _, body_line in ipairs(split_body(draft.body)) do
        virtual[#virtual + 1] = {
          { '  │ ', 'MeatReviewDraftRail' },
          { body_line, 'MeatReviewDraftText' },
        }
      end
      vim.api.nvim_buf_set_extmark(target.buf, comment_ns, line - 1, 0, {
        sign_text = '●',
        sign_hl_group = 'DiagnosticInfo',
        virt_lines = virtual,
        virt_lines_leftcol = true,
      })
    end
  end
end

local function normalize_body(lines)
  while #lines > 0 and lines[1]:match('^%s*$') do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match('^%s*$') do
    table.remove(lines)
  end
  return table.concat(lines, '\n')
end

local function edit_comment(target)
  local source_line = vim.api.nvim_win_get_cursor(0)[1]
  local location = target.view.locations[source_line]
  if not location then
    local text = target.view.lines[source_line] or ''
    local reason = text:sub(1, 1) == ' ' and 'Context lines cannot be annotated.'
      or 'This is not an exact retained changed line with a safe review location.'
    return notify(reason, vim.log.levels.WARN)
  end

  local key = comment_key(location)
  local existing = target.comments[key]
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.max(30, math.min(80, vim.o.columns - 8))
  local height = math.max(5, math.min(12, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = (' %s:%d (%s) '):format(location.path, location.line, location.side),
    title_pos = 'center',
  })
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_name(buf, ('meat-review://comment/%s/%s/%d'):format(location.path, location.side, location.line))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, existing and split_body(existing.body) or { '' })
  vim.wo[win].wrap = true
  vim.cmd('startinsert')

  local function save()
    local body = normalize_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if body == '' then
      target.comments[key] = nil
    else
      target.comments[key] = { location = vim.deepcopy(location), body = body }
    end
    vim.bo[buf].modified = false
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    refresh_comments(target)
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = save,
  })

  vim.keymap.set('n', 'q', function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', save, { buffer = buf })
end

local function delete_comment(target)
  local location = target.view.locations[vim.api.nvim_win_get_cursor(0)[1]]
  if not location or not target.comments[comment_key(location)] then
    return notify('There is no draft comment on this line.', vim.log.levels.WARN)
  end
  target.comments[comment_key(location)] = nil
  refresh_comments(target)
end

local function navigate(lines, direction)
  if #lines == 0 then
    return notify('There is nowhere to navigate.', vim.log.levels.WARN)
  end
  table.sort(lines)
  local current = vim.api.nvim_win_get_cursor(0)[1]
  if direction > 0 then
    for _, line in ipairs(lines) do
      if line > current then
        return vim.api.nvim_win_set_cursor(0, { line, 0 })
      end
    end
    vim.api.nvim_win_set_cursor(0, { lines[1], 0 })
  else
    for index = #lines, 1, -1 do
      if lines[index] < current then
        return vim.api.nvim_win_set_cursor(0, { lines[index], 0 })
      end
    end
    vim.api.nvim_win_set_cursor(0, { lines[#lines], 0 })
  end
end

local function navigate_comments(target, direction)
  local lines = {}
  for line, location in pairs(target.view.locations) do
    if target.comments[comment_key(location)] then
      lines[#lines + 1] = line
    end
  end
  navigate(lines, direction)
end

local function add_header(target, buf)
  local virtual
  if target.kind == 'commit' then
    local commit = target.commit
    local relation = commit.parent and ('%s ← %s'):format(short_sha(commit.parent), short_sha(commit.sha))
      or 'Root commit'
    virtual = {
      { { ('Commit %s — %s'):format(short_sha(commit.sha), commit.title), 'Title' } },
      { { commit.sha, 'Underlined' } },
      { { relation, 'Comment' } },
      { { ('Submission target: PR #%d — %s'):format(target.pr.number, target.pr.title), 'Comment' } },
    }
  else
    local pr = target.pr
    virtual = {
      { { ('PR #%d — %s'):format(pr.number, pr.title), 'Title' } },
      { { pr.url, 'Underlined' } },
      { { ('%s ← %s'):format(pr.baseRefName, pr.headRefName), 'Comment' } },
    }
  end
  virtual[#virtual + 1] = { { 'Meat: ' .. target.meat.summary, 'Comment' } }
  virtual[#virtual + 1] = { { 'Elision: ' .. tostring(target.meat.elision), 'Comment' } }
  if target.view.unmapped_count > 0 then
    virtual[#virtual + 1] = {
      { ('Warning: %d changed Meat row(s) could not be mapped.'):format(target.view.unmapped_count), 'WarningMsg' },
    }
  end
  virtual[#virtual + 1] = { { '' } }
  vim.api.nvim_buf_set_extmark(buf, review_ns, 0, 0, { virt_lines = virtual, virt_lines_above = true })
end

local function highlight_diff(buf, lines)
  for index, text in ipairs(lines) do
    local group
    if text:match('^── ') then
      group = 'Title'
    elseif text:match('^@@') then
      group = 'DiffText'
    elseif text:sub(1, 1) == '+' then
      group = 'DiffAdd'
    elseif text:sub(1, 1) == '-' then
      group = 'DiffDelete'
    elseif text:sub(1, 1) ~= ' ' then
      group = 'Comment'
    end
    if group then
      vim.api.nvim_buf_add_highlight(buf, review_ns, group, index - 1, 0, -1)
    end
  end
end

local function file_under_cursor(target)
  if target.state ~= 'open' or vim.api.nvim_get_current_buf() ~= target.buf then
    return nil, 'Open a Meat review and place the cursor inside a file first.'
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local file
  for _, file_line in ipairs(target.view.files) do
    if file_line > cursor_line then
      break
    end
    file = target.view.file_contexts[file_line]
  end
  if not file or not file.supported or not file.path then
    return nil, 'The current file does not have a supported Git path.'
  end
  local source_locations = target.view.source_locations or target.view.locations
  local location = source_locations[cursor_line]
  return {
    root = target.root,
    path = file.path,
    old_path = file.old_path,
    new_path = file.new_path,
    line = location and location.line or nil,
    side = location and location.side or nil,
    kind = target.kind,
    base_sha = target.base_sha,
    head_sha = target.head_sha,
  }
end

local function open_file_diff(target, context)
  local lines = diff.file_lines(target.raw_diff, context.path)
  if not lines then
    return notify('Could not recover the full diff for the current file.', vim.log.levels.ERROR)
  end
  vim.cmd('vsplit')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = 'diff'
  local name = ('meat-review://file/%s/%s/%s'):format(short_sha(target.head_sha), context.path, vim.uv.hrtime())
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = false
  highlight_diff(buf, lines)
  vim.keymap.set('n', 'q', function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true, silent = true, desc = 'Close full file diff' })
end

function M.open_file(selected)
  local target = selected or session
  local context, err = file_under_cursor(target)
  if err then
    return notify(err, vim.log.levels.WARN)
  end
  if config.open_file then
    local ok, opener_err = pcall(config.open_file, context)
    if not ok then
      notify('Configured file opener failed: ' .. process.concise_error(opener_err), vim.log.levels.ERROR)
    end
    return
  end
  open_file_diff(target, context)
end

local function close_tab()
  vim.cmd('tabclose')
end

local function open_review(target)
  vim.cmd('tabnew')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = 'diff'
  vim.api.nvim_buf_set_name(buf, 'Meat Review ' .. session_label(target))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, target.view.lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = 'yes'
  target.buf, target.win, target.state = buf, win, 'open'

  add_header(target, buf)
  highlight_diff(buf, target.view.lines)
  refresh_comments(target)

  local map = function(lhs, rhs, description)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = description })
  end
  map('a', function()
    edit_comment(target)
  end, 'Add or edit review comment')
  map('d', function()
    delete_comment(target)
  end, 'Delete review comment')
  map('[c', function()
    navigate_comments(target, -1)
  end, 'Previous draft comment')
  map(']c', function()
    navigate_comments(target, 1)
  end, 'Next draft comment')
  map('[f', function()
    navigate(vim.deepcopy(target.view.files), -1)
  end, 'Previous file')
  map(']f', function()
    navigate(vim.deepcopy(target.view.files), 1)
  end, 'Next file')
  map('o', function()
    M.open_file(target)
  end, 'Open full file diff')
  map('S', function()
    M.submit(target)
  end, 'Preview review submission')
  map('q', close_tab, 'Close review tab')

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      if target.buf == buf then
        target.buf, target.win, target.state = nil, nil, 'ready'
      end
    end,
  })
end

local function close_session_ui(target)
  if target.preview_win and vim.api.nvim_win_is_valid(target.preview_win) then
    vim.api.nvim_win_close(target.preview_win, true)
  end
  target.preview_buf, target.preview_win = nil, nil
  if target.win and vim.api.nvim_win_is_valid(target.win) then
    local tab = vim.api.nvim_win_get_tabpage(target.win)
    if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd('tabclose')
    elseif target.buf and vim.api.nvim_buf_is_valid(target.buf) then
      vim.api.nvim_buf_delete(target.buf, { force = true })
    end
  elseif target.buf and vim.api.nvim_buf_is_valid(target.buf) then
    vim.api.nvim_buf_delete(target.buf, { force = true })
  end
  target.buf, target.win = nil, nil
  if target.state == 'open' then
    target.state = 'ready'
  end
end

local function activate(target)
  if session ~= target then
    close_session_ui(session)
    session = target
  end
end

local function show_session(target)
  if target.state == 'ready' then
    open_review(target)
  elseif target.state == 'open' then
    if target.win and vim.api.nvim_win_is_valid(target.win) then
      vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(target.win))
      vim.api.nvim_set_current_win(target.win)
    else
      target.state = 'ready'
      open_review(target)
    end
  end
end

local function discovery_failed(message)
  checking_identity = false
  notify(message, vim.log.levels.ERROR)
end

local function select_discovered(identity, announced_start)
  checking_identity = false
  local cached = sessions.get(identity)
  if cached then
    local changed = cached ~= session
    activate(cached)
    if changed then
      notify('Restored cached Meat review for ' .. session_label(cached))
    end
    return show_session(cached)
  end

  local target = {
    kind = identity.kind,
    state = 'running',
    stage = 'Fetching GitHub diff',
    started_at = vim.uv.hrtime(),
    root = identity.root,
    repo = identity.repo,
    pr = identity.pr,
    commit = identity.commit,
    comments = {},
  }
  activate(target)
  if not announced_start then
    notify('Starting Meat review…')
  end
  local meat_options = {}
  if vim.env.MEAT_OPENAI_API_KEY and vim.env.MEAT_OPENAI_API_KEY ~= '' then
    meat_options.env = { OPENAI_API_KEY = vim.env.MEAT_OPENAI_API_KEY }
  end
  sessions.load(identity, meat_options, function(stage)
    target.stage = stage
  end, function(resolved, err)
    if err then
      return fail_review(target, err)
    end
    if session == target then
      session = resolved
    end
    notify(('Meat review ready for %s — run %s to open'):format(session_label(resolved), open_command(resolved)))
  end)
end

local function discover_review(discover, requires_gh)
  if checking_identity or session.state == 'running' or session.submitting then
    return notify('Meat review is still running…')
  end

  local announced_start = session.state == 'idle'
  checking_identity = true
  if announced_start then
    notify('Starting Meat review…')
  end
  run({ 'git', 'rev-parse', '--show-toplevel' }, {}, function(root, root_err)
    if root_err then
      return discovery_failed('Could not resolve repository root: ' .. root_err)
    end
    root = root:gsub('%s+$', '')
    if requires_gh and vim.fn.executable('gh') ~= 1 then
      return discovery_failed('Required executable not found: gh')
    end
    if vim.fn.executable('meat') ~= 1 then
      return discovery_failed('Required executable not found: meat')
    end

    discover(root, function(identity, err)
      if err then
        return discovery_failed(err)
      end
      select_discovered(identity, announced_start)
    end)
  end)
end

function M.open()
  discover_review(sessions.discover, true)
end

function M.open_commit()
  discover_review(sessions.discover_commit, true)
end

function M.status()
  if checking_identity then
    notify('Meat review: Discovering review target')
  elseif session.state == 'idle' then
    notify('No active Meat review.')
  elseif session.state == 'running' then
    local elapsed = math.floor((vim.uv.hrtime() - session.started_at) / 1e9)
    notify(('Meat review: %s (%ds elapsed)'):format(session.stage, elapsed))
  elseif session.state == 'ready' then
    notify(('Meat review ready for %s — run %s to open'):format(session_label(session), open_command(session)))
  elseif session.state == 'open' then
    notify('Meat review open for ' .. session_label(session))
  end
end

local function sorted_drafts(target)
  local drafts = {}
  for _, draft in pairs(target.comments) do
    drafts[#drafts + 1] = draft
  end
  table.sort(drafts, function(a, b)
    if a.location.path ~= b.location.path then
      return a.location.path < b.location.path
    end
    if a.location.line ~= b.location.line then
      return a.location.line < b.location.line
    end
    return a.location.side < b.location.side
  end)
  return drafts
end

local function submit_review(target, drafts, review_body, review_event, preview_win)
  if target.submitting then
    return notify('Review submission is already running…')
  end
  target.submitting = true
  local revision_fields = 'baseRefOid,headRefOid'
  local args = { 'gh', 'pr', 'view', tostring(target.pr.number), '--repo', target.repo, '--json', revision_fields }
  run(args, { cwd = target.root }, function(stdout, err)
    if err then
      target.submitting = false
      return notify('Could not refresh PR revision: ' .. err, vim.log.levels.ERROR)
    end
    local current, decode_err = decode(stdout, 'pull request revision')
    if not current then
      target.submitting = false
      return notify(decode_err, vim.log.levels.ERROR)
    end
    if current.baseRefOid ~= target.submission_base_sha or current.headRefOid ~= target.submission_head_sha then
      target.submitting = false
      return notify('PR revision changed since this review started; start a new Meat review.', vim.log.levels.ERROR)
    end

    local comments = {}
    for _, draft in ipairs(drafts) do
      comments[#comments + 1] = {
        path = draft.location.path,
        line = draft.location.line,
        side = draft.location.side,
        body = draft.body,
      }
    end
    local payload = vim.json.encode({
      commit_id = target.submission_head_sha,
      body = review_body,
      event = review_event,
      comments = comments,
    })
    local endpoint = ('repos/%s/pulls/%d/reviews'):format(target.repo, target.pr.number)
    run(
      { 'gh', 'api', '--method', 'POST', endpoint, '--input', '-' },
      { cwd = target.root, stdin = payload },
      function(body, api_err)
        target.submitting = false
        if api_err then
          return notify('GitHub review submission failed: ' .. api_err, vim.log.levels.ERROR)
        end
        local response = decode(body, 'GitHub review response') or {}
        for _, draft in ipairs(drafts) do
          local key = comment_key(draft.location)
          local current_draft = target.comments[key]
          if current_draft and current_draft.body == draft.body then
            target.comments[key] = nil
          end
        end
        if target.review_body == review_body and target.review_event == review_event then
          target.review_body = ''
          target.review_event = 'COMMENT'
        end
        refresh_comments(target)
        if preview_win and vim.api.nvim_win_is_valid(preview_win) then
          vim.api.nvim_win_close(preview_win, true)
        end
        notify('GitHub review submitted' .. (response.html_url and ': ' .. response.html_url or '.'))
      end
    )
  end)
end

local event_labels = { COMMENT = 'Comment', APPROVE = 'Approve', REQUEST_CHANGES = 'Request changes' }
local review_events = { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }
local event_descriptions = {
  COMMENT = 'Submit general feedback without explicit approval.',
  APPROVE = 'Submit feedback and approve merging these changes.',
  REQUEST_CHANGES = 'Submit feedback suggesting changes.',
}

local function confirm_submission(target, drafts, review_body, review_event, preview_win)
  local action = 'Submit ' .. event_labels[review_event]
  vim.ui.select({ 'Cancel', action }, { prompt = action .. ' review to GitHub?' }, function(choice)
    if choice == action then
      if not vim.deep_equal(drafts, sorted_drafts(target)) then
        return notify('Drafts changed after this preview was opened; open a fresh preview.', vim.log.levels.WARN)
      end
      submit_review(target, drafts, review_body, review_event, preview_win)
    end
  end)
end

local function render_submission_editor(buf, review_event, drafts)
  vim.api.nvim_buf_clear_namespace(buf, preview_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, preview_ns, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      { { 'Finish your review', 'Title' } },
      { { 'Top-level comment (Markdown)', 'Special' } },
      { { 'First line can be a summary; use the remaining lines for the full review.', 'Comment' } },
      { { '' } },
    },
  })

  local body = normalize_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  if body == '' then
    vim.api.nvim_buf_set_extmark(buf, preview_ns, 0, 0, {
      virt_text = { { 'Leave a comment', 'Comment' } },
      virt_text_pos = 'overlay',
    })
  end

  local virtual = { { { '' } }, { { 'Review action', 'Title' }, { '  <Tab>/<S-Tab> or 1/2/3', 'Comment' } } }
  for index, event in ipairs(review_events) do
    local marker = event == review_event and '●' or '○'
    local highlight = event == review_event and 'Special' or 'Normal'
    virtual[#virtual + 1] = { { ('  %s [%d] %s'):format(marker, index, event_labels[event]), highlight } }
    virtual[#virtual + 1] = { { '      ' .. event_descriptions[event], 'Comment' } }
  end
  virtual[#virtual + 1] = { { '' } }
  virtual[#virtual + 1] = { { ('Inline comments (%d)'):format(#drafts), 'Title' } }
  if #drafts == 0 then
    virtual[#virtual + 1] = { { '  No inline comments', 'Comment' } }
  end
  for _, draft in ipairs(drafts) do
    local location = draft.location
    virtual[#virtual + 1] = {
      { ('  %s · %s %d'):format(location.path, location.side, location.line), 'Special' },
    }
    for _, line in ipairs(split_body(draft.body)) do
      virtual[#virtual + 1] = { { '    ' .. line, 'Comment' } }
    end
  end
  virtual[#virtual + 1] = { { '' } }
  virtual[#virtual + 1] = {
    { 'S Submit review', 'Special' },
    { '   q Cancel (save draft)', 'Comment' },
    { '   D Discard top-level draft', 'Comment' },
  }
  local last_line = math.max(vim.api.nvim_buf_line_count(buf) - 1, 0)
  vim.api.nvim_buf_set_extmark(buf, preview_ns, last_line, 0, { virt_lines = virtual, virt_lines_leftcol = true })
end

function M.submit(selected)
  local target = selected or session
  if checking_identity or target.state == 'idle' or target.state == 'running' then
    return notify('No completed Meat review is available.', vim.log.levels.WARN)
  end
  if target.preview_win and vim.api.nvim_win_is_valid(target.preview_win) then
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(target.preview_win))
    return vim.api.nvim_set_current_win(target.preview_win)
  end

  if target.state == 'ready' then
    open_review(target)
  elseif target.win and vim.api.nvim_win_is_valid(target.win) then
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(target.win))
    vim.api.nvim_set_current_win(target.win)
  end

  local drafts = sorted_drafts(target)
  local review_event = target.review_event or 'COMMENT'
  local parent_win = vim.api.nvim_get_current_win()
  local parent_width = vim.api.nvim_win_get_width(parent_win)
  local parent_height = vim.api.nvim_win_get_height(parent_win)
  local width = math.min(96, math.max(1, parent_width - 4))
  local height = math.min(30, math.max(1, parent_height - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    win = parent_win,
    width = width,
    height = height,
    row = math.max(0, math.floor((parent_height - height) / 2) - 1),
    col = math.max(0, math.floor((parent_width - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' Finish your review ',
    title_pos = 'center',
  })
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_name(buf, ('meat-review://submission/%d'):format(target.pr.number))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_body(target.review_body or ''))
  vim.bo[buf].modified = false
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  target.preview_buf, target.preview_win = buf, win

  local function close_submission()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function save()
    target.review_body = normalize_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    target.review_event = review_event
    vim.bo[buf].modified = false
  end

  local function cycle_event(direction)
    local index = 1
    for candidate, event in ipairs(review_events) do
      if event == review_event then
        index = candidate
        break
      end
    end
    index = ((index - 1 + direction) % #review_events) + 1
    review_event = review_events[index]
    target.review_event = review_event
    render_submission_editor(buf, review_event, drafts)
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = save })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      render_submission_editor(buf, review_event, drafts)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      if target.preview_buf == buf then
        target.preview_buf, target.preview_win = nil, nil
      end
    end,
  })
  vim.keymap.set('n', '<Tab>', function()
    cycle_event(1)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<S-Tab>', function()
    cycle_event(-1)
  end, { buffer = buf, nowait = true, silent = true })
  for index, event in ipairs(review_events) do
    local selected_event = event
    vim.keymap.set('n', tostring(index), function()
      review_event = selected_event
      target.review_event = review_event
      render_submission_editor(buf, review_event, drafts)
    end, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set('n', 'q', function()
    save()
    close_submission()
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', 'D', function()
    target.review_body = ''
    target.review_event = 'COMMENT'
    vim.bo[buf].modified = false
    close_submission()
    notify('Top-level review draft discarded; inline comments were kept.')
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', 'S', function()
    save()
    if review_event == 'REQUEST_CHANGES' and target.review_body == '' then
      return notify('Request changes requires an overall review comment.', vim.log.levels.WARN)
    end
    if review_event == 'COMMENT' and target.review_body == '' and #drafts == 0 then
      return notify('Add an overall or inline comment before submitting.', vim.log.levels.WARN)
    end
    confirm_submission(target, drafts, target.review_body, review_event, win)
  end, { buffer = buf, nowait = true, silent = true })
  render_submission_editor(buf, review_event, drafts)
end

return M
