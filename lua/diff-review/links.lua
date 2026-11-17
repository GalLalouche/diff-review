local M = {}

local ns = vim.api.nvim_create_namespace("diff_review_links")

local function setup_highlights()
  vim.api.nvim_set_hl(0, "DiffReviewLink", { link = "Underlined", default = true })
end

local function find_token_on_line(line, pattern, cursor_col)
  local first_match = nil
  local init = 1
  while init <= #line do
    local s, e, id = line:find(pattern, init)
    if not s then
      break
    end
    local match = {
      col = s - 1,
      end_col = e,
      id = tonumber(id),
    }
    if cursor_col and cursor_col >= match.col and cursor_col < match.end_col then
      return match, true
    end
    if not first_match then
      first_match = match
    end
    init = e + 1
  end
  return first_match, false
end

local function parse_sections(lines)
  local sections = {
    action_items = nil,
    disagreements = nil,
  }
  for lnum, line in ipairs(lines) do
    if line:match("^#%s*[Aa]ction [Ii]tems%s*#$") then
      local start_lnum = (lnum > 1 and lines[lnum - 1]:match("^#+$")) and (lnum - 1) or lnum
      local body_lnum = (lines[lnum + 1] and lines[lnum + 1]:match("^#+$")) and (lnum + 2) or (lnum + 1)
      sections.action_items = { header_start = start_lnum, body_start = body_lnum, body_end = #lines }
    elseif line:match("^#%s*[Dd]isagreements%s*#$") then
      local start_lnum = (lnum > 1 and lines[lnum - 1]:match("^#+$")) and (lnum - 1) or lnum
      local body_lnum = (lines[lnum + 1] and lines[lnum + 1]:match("^#+$")) and (lnum + 2) or (lnum + 1)
      if sections.action_items and sections.action_items.body_end == #lines then
        sections.action_items.body_end = start_lnum - 1
      end
      sections.disagreements = { header_start = start_lnum, body_start = body_lnum, body_end = #lines }
    end
  end
  return sections
end

local function get_diff_end(sections, total_lines)
  local diff_end = total_lines
  if sections.action_items then
    diff_end = math.min(diff_end, sections.action_items.header_start - 1)
  end
  if sections.disagreements then
    diff_end = math.min(diff_end, sections.disagreements.header_start - 1)
  end
  return diff_end
end

local function find_action_item_def(lines, sections, target_id)
  local sec = sections.action_items
  if not sec then
    return nil
  end
  for lnum = sec.body_start, sec.body_end do
    local s, e, id = lines[lnum]:find("^%s*(%d+)%.")
    if s and tonumber(id) == target_id then
      local num_s = lines[lnum]:find("%d", s)
      return { lnum = lnum, col = (num_s or s) - 1, end_col = e }
    end
  end
  return nil
end

local function find_disagreement_def(lines, sections, target_id)
  local sec = sections.disagreements
  if not sec then
    return nil
  end
  for lnum = sec.body_start, sec.body_end do
    local s, e, id = lines[lnum]:find("^%s*[Dd]isagreement%s*#(%d+)[:]?")
    if not s then
      s, e, id = lines[lnum]:find("^%s*(%d+)%.")
    end
    if s and tonumber(id) == target_id then
      local tok_s = lines[lnum]:find("%S", s)
      return { lnum = lnum, col = (tok_s or s) - 1, end_col = e }
    end
  end
  return nil
end

local function find_inline_ref(lines, diff_end, pattern, target_id)
  for lnum = 1, diff_end do
    local init = 1
    local line = lines[lnum]
    while init <= #line do
      local s, e, id = line:find(pattern, init)
      if not s then
        break
      end
      if tonumber(id) == target_id then
        return { lnum = lnum, col = s - 1, end_col = e }
      end
      init = e + 1
    end
  end
  return nil
end

local function current_section_entry(lines, sec, cursor_lnum, entry_pattern, alt_pattern)
  if not sec or cursor_lnum < sec.body_start or cursor_lnum > sec.body_end then
    return nil
  end
  if lines[cursor_lnum]:match("^%s*$") or lines[cursor_lnum]:match("^#+$") then
    return nil
  end
  for lnum = cursor_lnum, sec.body_start, -1 do
    local line = lines[lnum]
    if line:match("^%s*$") then
      break
    end
    local _, _, id = line:find(entry_pattern)
    if not id and alt_pattern then
      _, _, id = line:find(alt_pattern)
    end
    if id then
      return tonumber(id)
    end
  end
  return nil
end

local function find_ref_in_note_block(lines, diff_end, cursor_lnum, cursor_col)
  local line = lines[cursor_lnum]
  local ai_match, ai_exact = find_token_on_line(line, "AI%s*#(%d+)", cursor_col)
  local dis_match, dis_exact = find_token_on_line(line, "[Dd]isagreement%s*#(%d+)", cursor_col)

  if ai_exact then
    return "ai", ai_match.id
  end
  if dis_exact then
    return "disagreement", dis_match.id
  end
  if ai_match then
    return "ai", ai_match.id
  end
  if dis_match then
    return "disagreement", dis_match.id
  end

  if line:match("^#>>") or line:match("^#<<") then
    for lnum = cursor_lnum + 1, diff_end do
      local next_line = lines[lnum]
      if not (next_line:match("^#>>") or next_line:match("^#<<")) then
        break
      end
      local m_ai = find_token_on_line(next_line, "AI%s*#(%d+)")
      if m_ai then
        return "ai", m_ai.id
      end
      local m_dis = find_token_on_line(next_line, "[Dd]isagreement%s*#(%d+)")
      if m_dis then
        return "disagreement", m_dis.id
      end
    end
  end

  return nil, nil
end

local function jump_to(win, target)
  local top_line = vim.fn.line("w0", win)
  local bot_line = vim.fn.line("w$", win)
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(win, { target.lnum, target.col })
  if target.lnum <= top_line + 2 or target.lnum >= bot_line then
    vim.cmd("normal! zz")
  end
end

local function collect_files(lines, diff_end)
  local files = {}
  local in_header = false
  for lnum = 1, diff_end do
    local line = lines[lnum]
    if line:match("^diff %-%-git ") then
      table.insert(files, { lnum = lnum, col = 0 })
      in_header = true
    elseif line:match("^%-%-%- ") and not in_header then
      if lines[lnum + 1] and lines[lnum + 1]:match("^%+%+%+ ") then
        table.insert(files, { lnum = lnum, col = 0 })
        in_header = true
      end
    elseif line:match("^@@ .- @@") then
      in_header = false
    end
  end
  return files
end

local function collect_inline_action_items(lines, diff_end)
  local items = {}
  for lnum = 1, diff_end do
    local s, e, id = lines[lnum]:find("AI%s*#(%d+)")
    if s then
      table.insert(items, { lnum = lnum, col = s - 1, end_col = e, id = tonumber(id) })
    end
  end
  return items
end

local function cycle_targets(targets, direction, empty_msg)
  if #targets == 0 then
    vim.notify("diff-review: " .. empty_msg, vim.log.levels.WARN)
    return
  end

  local win = vim.api.nvim_get_current_win()
  local cursor_lnum = vim.api.nvim_win_get_cursor(win)[1]
  local count = vim.v.count1
  local idx = nil

  if direction > 0 then
    for i, t in ipairs(targets) do
      if t.lnum > cursor_lnum then
        idx = i
        break
      end
    end
    idx = idx or 1
    idx = ((idx - 1 + (count - 1)) % #targets) + 1
  else
    for i = #targets, 1, -1 do
      if targets[i].lnum < cursor_lnum then
        idx = i
        break
      end
    end
    idx = idx or #targets
    idx = ((idx - 1 - (count - 1)) % #targets) + 1
  end

  jump_to(win, targets[idx])
end

function M.next_file()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diff_end = get_diff_end(parse_sections(lines), #lines)
  cycle_targets(collect_files(lines, diff_end), 1, "No files found in diff")
end

function M.prev_file()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diff_end = get_diff_end(parse_sections(lines), #lines)
  cycle_targets(collect_files(lines, diff_end), -1, "No files found in diff")
end

function M.next_action_item()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diff_end = get_diff_end(parse_sections(lines), #lines)
  cycle_targets(collect_inline_action_items(lines, diff_end), 1, "No action items found in diff")
end

function M.prev_action_item()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diff_end = get_diff_end(parse_sections(lines), #lines)
  cycle_targets(collect_inline_action_items(lines, diff_end), -1, "No action items found in diff")
end

function M.goto_link()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local cursor_lnum, cursor_col = cursor[1], cursor[2]

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sections = parse_sections(lines)
  local diff_end = get_diff_end(sections, #lines)

  if cursor_lnum <= diff_end then
    local kind, id = find_ref_in_note_block(lines, diff_end, cursor_lnum, cursor_col)
    if kind == "ai" then
      local target = find_action_item_def(lines, sections, id)
      if target then
        jump_to(win, target)
      else
        vim.notify("diff-review: Action item #" .. id .. " not found", vim.log.levels.WARN)
      end
      return
    elseif kind == "disagreement" then
      local target = find_disagreement_def(lines, sections, id)
      if target then
        jump_to(win, target)
      else
        vim.notify("diff-review: Disagreement #" .. id .. " not found", vim.log.levels.WARN)
      end
      return
    end
  else
    local ai_id = current_section_entry(lines, sections.action_items, cursor_lnum, "^%s*(%d+)%.")
    if ai_id then
      local target = find_inline_ref(lines, diff_end, "AI%s*#(%d+)", ai_id)
      if target then
        jump_to(win, target)
      else
        vim.notify("diff-review: Inline AI #" .. ai_id .. " not found", vim.log.levels.WARN)
      end
      return
    end

    local dis_id = current_section_entry(
      lines,
      sections.disagreements,
      cursor_lnum,
      "^%s*[Dd]isagreement%s*#(%d+)[:]?",
      "^%s*(%d+)%."
    )
    if dis_id then
      local target = find_inline_ref(lines, diff_end, "[Dd]isagreement%s*#(%d+)", dis_id)
      if target then
        jump_to(win, target)
      else
        vim.notify("diff-review: Inline Disagreement #" .. dis_id .. " not found", vim.log.levels.WARN)
      end
      return
    end
  end

  vim.cmd("normal! gd")
end

function M.highlight_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sections = parse_sections(lines)
  local diff_end = get_diff_end(sections, #lines)

  local function add_pattern_highlights(lnum, line, pattern)
    local init = 1
    while init <= #line do
      local s, e = line:find(pattern, init)
      if not s then
        break
      end
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, s - 1, {
        end_col = e,
        hl_group = "DiffReviewLink",
      })
      init = e + 1
    end
  end

  for lnum = 1, diff_end do
    local line = lines[lnum]
    add_pattern_highlights(lnum, line, "AI%s*#%d+")
    add_pattern_highlights(lnum, line, "[Dd]isagreement%s*#%d+")
  end

  if sections.action_items then
    for lnum = sections.action_items.body_start, sections.action_items.body_end do
      local line = lines[lnum]
      local s, e = line:find("^%s*%d+%.")
      if s then
        local num_s = line:find("%d", s) or s
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, num_s - 1, {
          end_col = e,
          hl_group = "DiffReviewLink",
        })
      end
    end
  end

  if sections.disagreements then
    for lnum = sections.disagreements.body_start, sections.disagreements.body_end do
      local line = lines[lnum]
      local s, e = line:find("^%s*[Dd]isagreement%s*#%d+[:]?")
      if not s then
        s, e = line:find("^%s*%d+%.")
      end
      if s then
        local tok_s = line:find("%S", s) or s
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, tok_s - 1, {
          end_col = e,
          hl_group = "DiffReviewLink",
        })
      end
    end
  end
end

function M.attach(buf, keys)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.keymap.set("n", keys.goto_link, M.goto_link, {
    buffer = buf,
    silent = true,
    desc = "Jump between inline AI/Disagreement and section entry",
  })
  vim.keymap.set("n", keys.next_file, M.next_file, {
    buffer = buf,
    silent = true,
    desc = "Jump to next file in diff",
  })
  vim.keymap.set("n", keys.prev_file, M.prev_file, {
    buffer = buf,
    silent = true,
    desc = "Jump to previous file in diff",
  })
  vim.keymap.set("n", keys.next_action_item, M.next_action_item, {
    buffer = buf,
    silent = true,
    desc = "Jump to next inline action item in diff",
  })
  vim.keymap.set("n", keys.prev_action_item, M.prev_action_item, {
    buffer = buf,
    silent = true,
    desc = "Jump to previous inline action item in diff",
  })
  M.highlight_buf(buf)
end

function M.setup(opts)
  opts = opts or {}
  local km = opts.keymaps or {}
  local keys = {
    goto_link = km.goto_link or "gd",
    next_file = km.next_file or "]f",
    prev_file = km.prev_file or "[f",
    next_action_item = km.next_action_item or "]a",
    prev_action_item = km.prev_action_item or "[a",
  }

  setup_highlights()

  local group = vim.api.nvim_create_augroup("DiffReviewLinks", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = setup_highlights,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "diff",
    callback = function(args)
      M.attach(args.buf, keys)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    group = group,
    callback = function(args)
      if vim.api.nvim_buf_is_valid(args.buf) and vim.bo[args.buf].filetype == "diff" then
        M.highlight_buf(args.buf)
      end
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "diff" then
      M.attach(buf, keys)
    end
  end
end

return M
