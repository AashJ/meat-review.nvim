local diff = require('meat-review.diff')

local tests = {}

local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or 'values differ') .. (': expected %q, got %q'):format(expected, actual), 2)
  end
end

local function location_for(view, text, occurrence)
  occurrence = occurrence or 1
  local seen = 0
  for line, value in ipairs(view.lines) do
    if value == text then
      seen = seen + 1
      if seen == occurrence then
        return view.locations[line], line
      end
    end
  end
end

local function one_file(body, old_path, new_path)
  old_path = old_path or 'a/example.lua'
  new_path = new_path or 'b/example.lua'
  return table.concat({
    'diff --git ' .. old_path .. ' ' .. new_path,
    'index 1111111..2222222 100644',
    '--- ' .. old_path,
    '+++ ' .. new_path,
    body,
  }, '\n')
end

test('maps additions, deletions, and advances counters on context', function()
  local raw = one_file(table.concat({
    '@@ -10,4 +20,4 @@ function example()',
    ' context',
    '-old',
    '+new',
    ' tail',
  }, '\n'))
  local view = diff.build_view(raw, raw)
  local deletion = location_for(view, '-old')
  local addition = location_for(view, '+new')
  equal(deletion.line, 11)
  equal(deletion.side, 'LEFT')
  equal(addition.line, 21)
  equal(addition.side, 'RIGHT')
end)

test('does not confuse header-like changed text with file metadata', function()
  local raw = one_file(table.concat({
    '@@ -1 +1 @@',
    '--- removed prose',
    '+++ added prose',
  }, '\n'))
  local view = diff.build_view(raw, raw)
  equal(location_for(view, '--- removed prose').line, 1)
  equal(location_for(view, '--- removed prose').side, 'LEFT')
  equal(location_for(view, '+++ added prose').line, 1)
  equal(location_for(view, '+++ added prose').side, 'RIGHT')
end)

test('maps retained rows when Meat removes rows and leaves stale counts', function()
  local raw = one_file(table.concat({
    '@@ -1,5 +1,5 @@',
    ' one',
    '-first old',
    '+first new',
    ' middle',
    '-second old',
    '+second new',
  }, '\n'))
  local smart = one_file(table.concat({
    '@@ -1,5 +1,5 @@',
    ' one',
    '-second old',
    '+second new',
  }, '\n'))
  local view = diff.build_view(raw, smart)
  equal(location_for(view, '-second old').line, 4)
  equal(location_for(view, '+second new').line, 4)
end)

test('handles multiple files and multiple hunks', function()
  local first = one_file(table.concat({ '@@ -1 +1 @@', '-a', '+b' }, '\n'))
  local second = one_file(
    table.concat({
      '@@ -5 +5 @@',
      '-c',
      '+d',
      '@@ -20 +20 @@',
      '-e',
      '+f',
    }, '\n'),
    'a/second.lua',
    'b/second.lua'
  )
  local raw = first .. '\n' .. second
  local view = diff.build_view(raw, raw)
  equal(#view.files, 2)
  local second_file = view.file_contexts[view.files[2]]
  equal(second_file.path, 'second.lua')
  local first_lines = diff.file_lines(raw, 'example.lua')
  local second_lines = diff.file_lines(raw, 'second.lua')
  equal(first_lines[#first_lines], '+b')
  equal(second_lines[#second_lines], '+f')
  equal(location_for(view, '+d').path, 'second.lua')
  equal(location_for(view, '+f').line, 20)
end)

test('resolves duplicate changed rows in source order', function()
  local raw = one_file(table.concat({
    '@@ -1,3 +1,3 @@',
    '-same',
    '+same',
    ' context',
    '-same',
    '+same',
  }, '\n'))
  local view = diff.build_view(raw, raw)
  equal(location_for(view, '+same', 1).line, 1)
  equal(location_for(view, '+same', 2).line, 3)
end)

test('maps commit rows onto unambiguous aggregate PR locations', function()
  local commit = one_file(table.concat({ '@@ -1 +10 @@', '-old', '+new' }, '\n'))
  local review = one_file(
    table.concat({
      '@@ -5 +10 @@',
      '-old',
      '+new',
      '@@ -20 +25 @@',
      '-old',
      '+other',
    }, '\n')
  )
  local view = diff.build_view(commit, commit)
  local _, deleted_line = location_for(view, '-old')
  local _, added_line = location_for(view, '+new')
  diff.map_review_locations(view, review, false)
  equal(view.source_locations[deleted_line].line, 1)
  equal(view.locations[deleted_line], nil, 'ambiguous deleted rows must not receive a PR anchor')
  equal(view.locations[added_line].line, 10)
  equal(view.locations[added_line].side, 'RIGHT')
  equal(view.unmapped_count, 1)
end)

test('maps new and deleted files', function()
  local new_file = one_file(table.concat({ '@@ -0,0 +1,2 @@', '+one', '+two' }, '\n'), '/dev/null', 'b/new.lua')
  local deleted = one_file(table.concat({ '@@ -3,2 +0,0 @@', '-old', '-gone' }, '\n'), 'a/old.lua', '/dev/null')
  local view = diff.build_view(new_file .. '\n' .. deleted, new_file .. '\n' .. deleted)
  equal(location_for(view, '+two').line, 2)
  equal(location_for(view, '+two').path, 'new.lua')
  equal(location_for(view, '-old').line, 3)
  equal(location_for(view, '-old').path, 'old.lua')
end)

test('uses the new path for an unquoted rename', function()
  local raw = table.concat({
    'diff --git a/old.lua b/new.lua',
    'similarity index 80%',
    'rename from old.lua',
    'rename to new.lua',
    '--- a/old.lua',
    '+++ b/new.lua',
    '@@ -1 +1 @@',
    '-old',
    '+new',
  }, '\n')
  local view = diff.build_view(raw, raw)
  equal(location_for(view, '+new').path, 'new.lua')
end)

test('makes fixed folds and partial elisions non-commentable', function()
  local raw = one_file(table.concat({ '@@ -1 +1 @@', '-original', '+replacement' }, '\n'))
  local smart = one_file(table.concat({ '@@ -1 +1 @@', '-...', '+replace...ment', '+…' }, '\n'))
  local view = diff.build_view(raw, smart)
  equal(location_for(view, '-...'), nil)
  equal(location_for(view, '+replace...ment'), nil)
  equal(location_for(view, '+…'), nil)
  equal(view.unmapped_count, 0)
end)

test('displays and counts unmappable changed rows', function()
  local raw = one_file(table.concat({ '@@ -1 +1 @@', '-old', '+new' }, '\n'))
  local smart = one_file(table.concat({ '@@ -1 +1 @@', '-invented', '+new' }, '\n'))
  local view = diff.build_view(raw, smart)
  equal(location_for(view, '-invented'), nil)
  equal(view.unmapped_count, 1)
  equal(location_for(view, '+new').line, 1)
end)

test('refuses quoted and unsupported paths', function()
  local quoted = table.concat({
    'diff --git "a/quoted name.lua" "b/quoted name.lua"',
    '--- "a/quoted name.lua"',
    '+++ "b/quoted name.lua"',
    '@@ -1 +1 @@',
    '-old',
    '+new',
  }, '\n')
  local unsupported = one_file(table.concat({ '@@ -1 +1 @@', '-x', '+y' }, '\n'), 'old.lua', 'new.lua')
  local view = diff.build_view(quoted .. '\n' .. unsupported, quoted .. '\n' .. unsupported)
  equal(location_for(view, '+new'), nil)
  equal(location_for(view, '+y'), nil)
end)

local failures = 0
for _, entry in ipairs(tests) do
  local ok, err = pcall(entry[2])
  if ok then
    print('ok - ' .. entry[1])
  else
    failures = failures + 1
    print('not ok - ' .. entry[1] .. '\n  ' .. tostring(err))
  end
end

if failures > 0 then
  error(('%d test(s) failed'):format(failures))
end

print(('%d tests passed'):format(#tests))
