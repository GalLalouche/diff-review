local M = {}

local ns = vim.api.nvim_create_namespace("diff_review_sticky")
local win_state = {}
local enabled = true

local function setup_highlights()
  local bg_target = vim.fn.hlexists("TreesitterContext") == 1 and "TreesitterContext" or "CursorLine"
  vim.api.nvim_set_hl(0, "DiffReviewStickyBg", { link = bg_target, default = true })
  vim.api.nvim_set_hl(0, "DiffReviewStickyLineNr", { link = "LineNr", default = true })
  vim.api.nvim_set_hl(0, "DiffReviewStickyFile", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "DiffReviewStickyHunk", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "DiffReviewStickyFunc", { link = "Function", default = true })
end

local function clean_path(raw)
  if not raw then
    return nil
  end
  local path = raw:gsub("\t.*$", "")
  if path == "/dev/null" then
    return path
  end
  return path:gsub("^[ab]/", "")
end

local function format_file_label(file)
  if file.new_path == "/dev/null" and file.old_path then
    return file.old_path .. " (deleted)"
  end
  if file.old_path and file.new_path and file.old_path ~= "/dev/null" and file.old_path ~= file.new_path then
    return file.old_path .. " -> " .. file.new_path
  end
  return file.new_path or file.git_b or file.old_path or file.git_a
end

local function parse_context(buf, top_line)
  local total = vim.api.nvim_buf_line_count(buf)
  local scan_end = math.min(total, top_line + 4)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, scan_end, false)

  local cur_file = nil
  local cur_hunk = nil
  local in_header = false
  local next_section_at_row1 = false

  for lnum = 1, scan_end do
    local line = lines[lnum]

    local git_a, git_b = line:match("^diff %-%-git a/(.+) b/(.+)$")
    if git_a then
      if lnum <= top_line then
        cur_file = { lnum = lnum, git_a = git_a, git_b = git_b }
        cur_hunk = nil
        in_header = true
      else
        if lnum == top_line + 1 then
          next_section_at_row1 = true
        end
        break
      end
    elseif line:match("^%-%-%- ") then
      local old_path = clean_path(line:sub(5))
      if not in_header then
        if lines[lnum + 1] and lines[lnum + 1]:match("^%+%+%+ ") then
          if lnum <= top_line then
            cur_file = { lnum = lnum, old_path = old_path }
            cur_hunk = nil
            in_header = true
          else
            if lnum == top_line + 1 then
              next_section_at_row1 = true
            end
            break
          end
        end
      elseif cur_file then
        cur_file.old_path = old_path
      end
    elseif in_header and line:match("^%+%+%+ ") and cur_file then
      cur_file.new_path = clean_path(line:sub(5))
    elseif line:match("^@@ .- @@") then
      in_header = false
      if lnum <= top_line + 1 and not next_section_at_row1 then
        cur_hunk = { lnum = lnum, text = line }
      end
    elseif line:match("^# Action items #$") or line:match("^# Disagreements #$") then
      local section_start = (lnum > 1 and lines[lnum - 1]:match("^#+$")) and (lnum - 1) or lnum
      if section_start <= top_line then
        cur_file = nil
        cur_hunk = nil
        in_header = false
      else
        if section_start == top_line + 1 then
          next_section_at_row1 = true
        end
        break
      end
    end
  end

  if not cur_file or cur_file.lnum >= top_line then
    return {}
  end

  local items = {
    { lnum = cur_file.lnum, kind = "file", text = format_file_label(cur_file) or "" },
  }
  if cur_hunk and not next_section_at_row1 then
    table.insert(items, { lnum = cur_hunk.lnum, kind = "hunk", text = cur_hunk.text })
  end
  return items
end

local function close_win_float(win)
  local st = win_state[win]
  if not st then
    return
  end
  if st.float_win and vim.api.nvim_win_is_valid(st.float_win) then
    vim.api.nvim_win_close(st.float_win, true)
  end
  if st.float_buf and vim.api.nvim_buf_is_valid(st.float_buf) then
    vim.api.nvim_buf_delete(st.float_buf, { force = true })
  end
  win_state[win] = nil
end

local function is_diff_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end
  return vim.bo[buf].filetype == "diff"
end

function M.update_win(win)
  if not enabled or not vim.api.nvim_win_is_valid(win) then
    close_win_float(win)
    return
  end

  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return
  end

  local buf = vim.api.nvim_win_get_buf(win)
  if not is_diff_buf(buf) then
    close_win_float(win)
    return
  end

  local top_line = vim.fn.line("w0", win)
  local items = parse_context(buf, top_line)

  local cursor_offset = vim.api.nvim_win_get_cursor(win)[1] - top_line
  while #items > cursor_offset do
    table.remove(items)
  end

  if #items == 0 then
    close_win_float(win)
    return
  end

  local wininfo = vim.fn.getwininfo(win)[1]
  local textoff = wininfo and wininfo.textoff or 0
  local show_nr = textoff > 0 and (vim.wo[win].number or vim.wo[win].relativenumber)
  local width = vim.api.nvim_win_get_width(win)

  local rendered = {}
  local highlights = {}

  for i, item in ipairs(items) do
    local prefix = ""
    if show_nr then
      local nr_str = tostring(item.lnum)
      local pad = math.max(0, textoff - 1 - #nr_str)
      prefix = string.rep(" ", pad) .. nr_str .. " "
    elseif textoff > 0 then
      prefix = string.rep(" ", textoff)
    end

    local line_text = prefix .. item.text
    table.insert(rendered, line_text)

    local row = i - 1
    if #prefix > 0 then
      table.insert(highlights, { row, 0, #prefix, "DiffReviewStickyLineNr" })
    end
    if item.kind == "file" then
      table.insert(highlights, { row, #prefix, #line_text, "DiffReviewStickyFile" })
    else
      local range_end = item.text:find("@@", 3, true)
      if range_end then
        local split_col = #prefix + range_end + 1
        table.insert(highlights, { row, #prefix, split_col, "DiffReviewStickyHunk" })
        table.insert(highlights, { row, split_col, #line_text, "DiffReviewStickyFunc" })
      else
        table.insert(highlights, { row, #prefix, #line_text, "DiffReviewStickyHunk" })
      end
    end
  end

  local st = win_state[win]
  if not st or not st.float_buf or not vim.api.nvim_buf_is_valid(st.float_buf) then
    local float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].buftype = "nofile"
    vim.bo[float_buf].bufhidden = "wipe"
    vim.bo[float_buf].swapfile = false
    st = { float_buf = float_buf, float_win = nil }
    win_state[win] = st
  end

  vim.bo[st.float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.float_buf, 0, -1, false, rendered)
  vim.bo[st.float_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(st.float_buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(st.float_buf, ns, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end

  local win_cfg = {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = width,
    height = #rendered,
    focusable = false,
    zindex = 50,
    style = "minimal",
  }

  if st.float_win and vim.api.nvim_win_is_valid(st.float_win) then
    vim.api.nvim_win_set_config(st.float_win, win_cfg)
  else
    st.float_win = vim.api.nvim_open_win(st.float_buf, false, win_cfg)
    vim.wo[st.float_win].winhl = "Normal:DiffReviewStickyBg,NormalFloat:DiffReviewStickyBg"
    vim.wo[st.float_win].wrap = false
  end
end

function M.update_all()
  for win in pairs(win_state) do
    if not vim.api.nvim_win_is_valid(win) then
      close_win_float(win)
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    M.update_win(win)
  end
end

function M.toggle()
  enabled = not enabled
  M.update_all()
  return enabled
end

function M.setup()
  setup_highlights()

  local group = vim.api.nvim_create_augroup("DiffReviewSticky", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = setup_highlights,
  })

  vim.api.nvim_create_autocmd({
    "WinScrolled",
    "CursorMoved",
    "CursorMovedI",
    "BufEnter",
    "WinEnter",
    "BufWinEnter",
    "TextChanged",
    "TextChangedI",
    "VimResized",
    "OptionSet",
  }, {
    group = group,
    callback = function()
      M.update_all()
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if closed_win then
        close_win_float(closed_win)
      end
    end,
  })

  M.update_all()
end

return M
