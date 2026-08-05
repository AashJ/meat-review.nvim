local M = {}

function M.concise_error(stderr)
  local message = (stderr or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
  if message == '' then
    return 'command failed without an error message'
  end
  if #message > 500 then
    return message:sub(1, 497) .. '...'
  end
  return message
end

function M.run(args, options, callback)
  vim.system(args, options or {}, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, M.concise_error(result.stderr))
      else
        callback(result.stdout or '', nil)
      end
    end)
  end)
end

function M.decode(value, label)
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok or type(decoded) ~= 'table' then
    return nil, ('invalid %s JSON'):format(label)
  end
  return decoded
end

return M
