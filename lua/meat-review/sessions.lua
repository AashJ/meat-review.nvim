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
  return { root = root, repo = repo, pr = pr }
end

local function revision_matches(left, right)
  return left.pr.number == right.pr.number
    and left.pr.baseRefOid == right.pr.baseRefOid
    and left.pr.headRefOid == right.pr.headRefOid
end

function M.key(value)
  return table.concat({
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
    cached.repo = value.repo
    cached.pr = value.pr
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
    callback(identity(root, repo, pr))
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

function M.load(discovered, meat_options, on_stage, callback)
  local cached = M.get(discovered)
  if cached then
    return callback(cached)
  end

  fetch_snapshot(discovered, 1, on_stage, function(snapshot, snapshot_err)
    if snapshot_err then
      return callback(nil, snapshot_err)
    end
    if snapshot.cached then
      return callback(snapshot.cached)
    end

    local current = snapshot.identity
    on_stage('Running Meat')
    local options = vim.tbl_extend('force', meat_options or {}, {
      cwd = current.root,
      stdin = snapshot.raw_diff,
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
      local ok, view = pcall(diff.build_view, snapshot.raw_diff, meat.smart_diff)
      if not ok then
        return callback(nil, 'Could not map Meat diff: ' .. process.concise_error(view))
      end

      local result = {
        key = M.key(current),
        state = 'ready',
        root = current.root,
        repo = current.repo,
        pr = current.pr,
        raw_diff = snapshot.raw_diff,
        meat = meat,
        view = view,
        base_sha = current.pr.baseRefOid,
        head_sha = current.pr.headRefOid,
        comments = {},
        review_body = '',
        review_event = 'COMMENT',
      }
      cache[result.key] = result
      callback(result)
    end)
  end)
end

return M
