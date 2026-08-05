local M = {}

local diff = require('meat-review.diff')
local process = require('meat-review.process')

local cache = {}
local fields = 'number,url,title,state,baseRefName,baseRefOid,headRefName,headRefOid'
local max_snapshot_attempts = 3

local function valid_oid(value)
  return type(value) == 'string' and value ~= ''
end

local function validate_pr(pr)
  if pr.state ~= 'OPEN' then
    return nil, 'The current branch does not have an open pull request'
  end
  if type(pr.number) ~= 'number' or not valid_oid(pr.baseRefOid) or not valid_oid(pr.headRefOid) then
    return nil, 'Pull request metadata is incomplete'
  end
  return pr
end

local function identity(root, repo, pr)
  return { kind = 'pr', root = root, repo = repo, pr = pr }
end

local function repository_from_pr(pr)
  if type(pr.url) ~= 'string' then
    return nil
  end
  return pr.url:match('^https?://[^/]+/([^/]+/[^/]+)/pull/%d+/?$')
end

local function revision_matches(left, right)
  return left.pr.number == right.pr.number
    and left.pr.baseRefOid == right.pr.baseRefOid
    and left.pr.headRefOid == right.pr.headRefOid
end

function M.key(value)
  if value.kind == 'commit' then
    return table.concat({
      'commit',
      value.repo,
      tostring(value.pr.number),
      value.pr.baseRefOid,
      value.commit.parent or 'ROOT',
      value.commit.sha,
    }, '\0')
  end
  return table.concat({
    'pr',
    value.repo,
    tostring(value.pr.number),
    value.pr.baseRefOid,
    value.pr.headRefOid,
  }, '\0')
end

function M.get(value)
  local cached = cache[M.key(value)]
  if cached then
    cached.root = value.root
    if value.kind == 'pr' then
      cached.repo = value.repo
      cached.pr = value.pr
    else
      cached.repo = value.repo
      cached.pr = value.pr
      cached.commit = value.commit
    end
  end
  return cached
end

local function read_pr(root, repo, number, callback)
  local args = { 'gh', 'pr', 'view' }
  if number then
    vim.list_extend(args, { tostring(number), '--repo', repo })
  end
  vim.list_extend(args, { '--json', fields })
  process.run(args, { cwd = root }, function(pr_json, pr_err)
    if pr_err then
      return callback(nil, 'Could not find a pull request for the current branch: ' .. pr_err)
    end
    local pr, decode_err = process.decode(pr_json, 'pull request')
    if not pr then
      return callback(nil, decode_err)
    end
    local valid, validation_err = validate_pr(pr)
    if not valid then
      return callback(nil, validation_err)
    end
    local pr_repo = repository_from_pr(pr)
    if not pr_repo then
      return callback(nil, 'Pull request URL is missing or unsupported')
    end
    callback(identity(root, pr_repo, pr))
  end)
end

function M.discover(root, callback)
  process.run({ 'gh', 'repo', 'view', '--json', 'nameWithOwner' }, { cwd = root }, function(repo_json, repo_err)
    if repo_err then
      return callback(nil, 'Could not identify GitHub repository: ' .. repo_err)
    end
    local repo, decode_err = process.decode(repo_json, 'repository')
    if not repo then
      return callback(nil, decode_err)
    end
    if type(repo.nameWithOwner) ~= 'string' or not repo.nameWithOwner:match('^[^/]+/[^/]+$') then
      return callback(nil, 'GitHub repository identity is missing or unsupported')
    end
    read_pr(root, repo.nameWithOwner, nil, callback)
  end)
end

function M.discover_commit(root, callback)
  local args = { 'git', 'show', '-s', '--format=%H%n%P%n%s', 'HEAD' }
  process.run(args, { cwd = root }, function(stdout, err)
    if err then
      return callback(nil, 'Could not resolve the current commit: ' .. err)
    end
    local lines = vim.split(stdout, '\n', { plain = true })
    local sha = lines[1]
    if not valid_oid(sha) then
      return callback(nil, 'Current commit metadata is incomplete')
    end
    local parents = lines[2] or ''
    local commit = {
      sha = sha,
      parent = parents:match('^(%S+)'),
      title = lines[3] or '',
    }
    M.discover(root, function(discovered, discovery_err)
      if discovery_err then
        return callback(nil, discovery_err)
      end
      if discovered.pr.headRefOid ~= commit.sha then
        return callback(nil, 'Local HEAD does not match the current pull request head')
      end
      discovered.kind = 'commit'
      discovered.commit = commit
      callback(discovered)
    end)
  end)
end

local function fetch_snapshot(current, attempt, on_stage, callback)
  on_stage('Fetching GitHub diff')
  local args = { 'gh', 'pr', 'diff', tostring(current.pr.number), '--repo', current.repo }
  process.run(args, { cwd = current.root }, function(raw_diff, diff_err)
    if diff_err then
      return callback(nil, 'Could not fetch PR diff: ' .. diff_err)
    end

    on_stage('Validating PR revision')
    read_pr(current.root, current.repo, current.pr.number, function(latest, validation_err)
      if validation_err then
        return callback(nil, validation_err)
      end
      if revision_matches(current, latest) then
        return callback({ identity = current, raw_diff = raw_diff })
      end
      if current.kind == 'commit' then
        return callback(nil, 'Pull request changed while fetching its diff; refresh local HEAD and try again.')
      end
      local cached = M.get(latest)
      if cached then
        return callback({ cached = cached })
      end
      if attempt >= max_snapshot_attempts then
        return callback(nil, 'Pull request changed repeatedly while fetching its diff; try again.')
      end
      fetch_snapshot(latest, attempt + 1, on_stage, callback)
    end)
  end)
end

local function build_session(current, raw_diff, review_diff, meat_options, on_stage, callback)
  on_stage('Running Meat')
  local options = vim.tbl_extend('force', meat_options or {}, {
    cwd = current.root,
    stdin = raw_diff,
  })
  process.run({ 'meat', '-json' }, options, function(meat_json, meat_err)
    if meat_err then
      return callback(nil, 'Meat failed: ' .. meat_err)
    end
    local meat, decode_err = process.decode(meat_json, 'Meat result')
    if not meat then
      return callback(nil, decode_err)
    end
    if type(meat.summary) ~= 'string' or type(meat.smart_diff) ~= 'string' or meat.elision == nil then
      return callback(nil, 'Meat result is missing summary, elision, or smart_diff')
    end

    on_stage('Mapping review')
    local ok, view = pcall(function()
      local built = diff.build_view(raw_diff, meat.smart_diff)
      if current.kind == 'commit' then
        diff.map_review_locations(built, review_diff, current.commit.parent == current.pr.baseRefOid)
      end
      return built
    end)
    if not ok then
      return callback(nil, 'Could not map Meat diff: ' .. process.concise_error(view))
    end

    local result = {
      key = M.key(current),
      kind = current.kind,
      state = 'ready',
      root = current.root,
      raw_diff = raw_diff,
      meat = meat,
      view = view,
      comments = {},
      review_body = '',
      review_event = 'COMMENT',
    }
    if current.kind == 'pr' then
      result.repo = current.repo
      result.pr = current.pr
      result.base_sha = current.pr.baseRefOid
      result.head_sha = current.pr.headRefOid
    else
      result.repo = current.repo
      result.pr = current.pr
      result.commit = current.commit
      result.base_sha = current.commit.parent
      result.head_sha = current.commit.sha
    end
    result.submission_base_sha = current.pr.baseRefOid
    result.submission_head_sha = current.pr.headRefOid
    cache[result.key] = result
    callback(result)
  end)
end

local function load_commit(discovered, review_diff, meat_options, on_stage, callback)
  on_stage('Fetching commit diff')
  local commit = discovered.commit
  local args
  if commit.parent then
    args = { 'git', 'diff', '--no-ext-diff', commit.parent, commit.sha }
  else
    args = { 'git', 'show', '--format=', '--root', '--no-ext-diff', commit.sha }
  end
  process.run(args, { cwd = discovered.root }, function(raw_diff, err)
    if err then
      return callback(nil, 'Could not read the current commit diff: ' .. err)
    end
    build_session(discovered, raw_diff, review_diff, meat_options, on_stage, callback)
  end)
end

function M.load(discovered, meat_options, on_stage, callback)
  local cached = M.get(discovered)
  if cached then
    return callback(cached)
  end
  if discovered.kind == 'commit' then
    return fetch_snapshot(discovered, 1, on_stage, function(snapshot, snapshot_err)
      if snapshot_err then
        return callback(nil, snapshot_err)
      end
      load_commit(snapshot.identity, snapshot.raw_diff, meat_options, on_stage, callback)
    end)
  end

  fetch_snapshot(discovered, 1, on_stage, function(snapshot, snapshot_err)
    if snapshot_err then
      return callback(nil, snapshot_err)
    end
    if snapshot.cached then
      return callback(snapshot.cached)
    end
    build_session(snapshot.identity, snapshot.raw_diff, snapshot.raw_diff, meat_options, on_stage, callback)
  end)
end

return M
