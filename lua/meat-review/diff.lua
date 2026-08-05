local M = {}

local function split_lines(text)
  local lines = {}
  text = text:gsub('\r\n', '\n')
  for line in (text .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = line
  end
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

local function header_path(line, prefix, path_prefix)
  local value = line:sub(#prefix + 1)
  value = value:match('^[^\t]*') or value
  if value == '/dev/null' then
    return nil, true
  end
  if value:sub(1, 1) == '"' or value:sub(1, 2) ~= path_prefix then
    return nil, false
  end
  value = value:sub(3)
  if value == '' or value:find('\0', 1, true) or value:find('\r', 1, true) or value:find('\n', 1, true) then
    return nil, false
  end
  return value, true
end

local function parse_raw(raw_diff, include_raw_lines)
  local parsed = { files = {}, rows = {} }
  local file
  local old_line, new_line

  for _, text in ipairs(split_lines(raw_diff)) do
    if include_raw_lines and file and not text:match('^diff %-%-git ') then
      file.raw_lines[#file.raw_lines + 1] = text
    end
    if text:match('^diff %-%-git ') then
      file = { supported = true, raw_lines = include_raw_lines and { text } or nil }
      parsed.files[#parsed.files + 1] = file
      parsed.rows[#parsed.rows + 1] = { kind = 'file', text = text, file = file }
      old_line, new_line = nil, nil
    elseif file and not old_line and text:sub(1, 4) == '--- ' then
      local path, ok = header_path(text, '--- ', 'a/')
      file.old_path = path
      file.supported = file.supported and ok
    elseif file and not new_line and text:sub(1, 4) == '+++ ' then
      local path, ok = header_path(text, '+++ ', 'b/')
      file.new_path = path
      file.supported = file.supported and ok
      file.path = file.new_path or file.old_path
      file.supported = file.supported and file.path ~= nil
    elseif file and text:match('^@@') then
      local old_start, new_start = text:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
      old_line, new_line = tonumber(old_start), tonumber(new_start)
      parsed.rows[#parsed.rows + 1] = { kind = 'hunk', text = text, file = file }
    elseif file and old_line and new_line then
      local prefix = text:sub(1, 1)
      local row = { text = text, file = file }
      if prefix == ' ' then
        row.kind = 'context'
        old_line, new_line = old_line + 1, new_line + 1
      elseif prefix == '-' then
        row.kind = 'delete'
        row.location = { line = old_line, side = 'LEFT', text = text:sub(2) }
        old_line = old_line + 1
      elseif prefix == '+' then
        row.kind = 'add'
        row.location = { line = new_line, side = 'RIGHT', text = text:sub(2) }
        new_line = new_line + 1
      else
        row.kind = 'meta'
      end
      parsed.rows[#parsed.rows + 1] = row
    end
  end

  for _, candidate in ipairs(parsed.files) do
    candidate.path = candidate.path or candidate.new_path or candidate.old_path
    candidate.supported = candidate.supported and candidate.path ~= nil
  end
  return parsed
end

function M.file_lines(raw_diff, path)
  assert(type(raw_diff) == 'string', 'raw_diff must be a string')
  assert(type(path) == 'string', 'path must be a string')
  for _, file in ipairs(parse_raw(raw_diff, true).files) do
    if file.path == path then
      return file.raw_lines
    end
  end
end

local function location_key(location)
  return table.concat({ location.path, location.side, location.text, tostring(location.line) }, '\0')
end

local function add_candidate(candidates, key, location)
  local matches = candidates[key]
  if not matches then
    matches = {}
    candidates[key] = matches
  end
  matches[#matches + 1] = location
end

function M.map_review_locations(view, review_diff, same_base)
  assert(type(view) == 'table' and type(view.locations) == 'table', 'view must contain locations')
  assert(type(review_diff) == 'string', 'review_diff must be a string')

  local exact = {}
  for _, row in ipairs(parse_raw(review_diff).rows) do
    if row.location and row.file.supported then
      local location = {
        path = row.file.path,
        line = row.location.line,
        side = row.location.side,
        text = row.location.text,
      }
      add_candidate(exact, location_key(location), location)
    end
  end

  local source_locations = view.locations
  local mapped_locations, used = {}, {}
  for line, source in pairs(source_locations) do
    local matches = (source.side == 'RIGHT' or same_base) and exact[location_key(source)] or nil
    local mapped = matches and #matches == 1 and matches[1] or nil
    if mapped and not used[mapped] then
      used[mapped] = true
      mapped_locations[line] = vim.deepcopy(mapped)
    else
      view.unmapped_count = view.unmapped_count + 1
    end
  end
  view.source_locations = source_locations
  view.locations = mapped_locations
  return view
end

local function is_elision(text)
  return text == '+...' or text == '-...' or text:find('...', 1, true) ~= nil or text:find('…', 1, true) ~= nil
end

local function find_row(rows, cursor, text, kind, file)
  for index = cursor, #rows do
    local row = rows[index]
    if row.file == file and row.kind == kind and row.text == text then
      return index, row
    end
    if row.kind == 'file' and row.file ~= file then
      break
    end
  end
end

local function row_kind(text)
  local prefix = text:sub(1, 1)
  if prefix == ' ' then
    return 'context'
  elseif prefix == '+' then
    return 'add'
  elseif prefix == '-' then
    return 'delete'
  end
  return 'meta'
end

function M.build_view(raw_diff, smart_diff)
  assert(type(raw_diff) == 'string', 'raw_diff must be a string')
  assert(type(smart_diff) == 'string', 'smart_diff must be a string')

  local original = parse_raw(raw_diff)
  local view = { lines = {}, locations = {}, files = {}, file_contexts = {}, unmapped_count = 0 }
  local file, cursor, in_hunk = nil, 1, false

  local function append(text)
    view.lines[#view.lines + 1] = text
    return #view.lines
  end

  for _, text in ipairs(split_lines(smart_diff)) do
    if text:match('^diff %-%-git ') then
      file = nil
      in_hunk = false
      for index = cursor, #original.rows do
        local row = original.rows[index]
        if row.kind == 'file' and row.text == text then
          file = row.file
          cursor = index + 1
          break
        end
      end
      local heading = file and file.path or 'Unsupported Git path'
      local rendered = append('── ' .. heading .. ' ──')
      view.files[#view.files + 1] = rendered
      if file then
        view.file_contexts[rendered] = {
          path = file.path,
          old_path = file.old_path,
          new_path = file.new_path,
          supported = file.supported,
        }
      end
    elseif not in_hunk and (text:match('^index ') or text:sub(1, 4) == '--- ' or text:sub(1, 4) == '+++ ') then
      -- Replaced by the clean file heading.
    elseif text:match('^@@') then
      in_hunk = true
      local found = file and find_row(original.rows, cursor, text, 'hunk', file)
      if found then
        cursor = found + 1
      end
      append(text)
    elseif file and (text:sub(1, 1) == ' ' or text:sub(1, 1) == '+' or text:sub(1, 1) == '-') then
      local kind = row_kind(text)
      local rendered = append(text)
      if not is_elision(text) then
        local found, source = find_row(original.rows, cursor, text, kind, file)
        if found then
          cursor = found + 1
          if source.location and file.supported then
            view.locations[rendered] = {
              path = file.path,
              line = source.location.line,
              side = source.location.side,
              text = source.location.text,
            }
          end
        elseif kind == 'add' or kind == 'delete' then
          view.unmapped_count = view.unmapped_count + 1
        end
      end
    elseif
      not text:match('^similarity index ')
      and not text:match('^rename from ')
      and not text:match('^rename to ')
    then
      append(text)
    end
  end

  return view
end

return M
