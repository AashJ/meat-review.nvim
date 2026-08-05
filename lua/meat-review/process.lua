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
        local details = {}
        if result.stderr and result.stderr ~= '' then
          details[#details + 1] = result.stderr
        end
        if result.stdout and result.stdout ~= '' then
          details[#details + 1] = result.stdout
        end
        callback(nil, M.concise_error(table.concat(details, '\n')))
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
