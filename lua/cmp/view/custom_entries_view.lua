local event = require('cmp.utils.event')
local autocmd = require('cmp.utils.autocmd')
local feedkeys = require('cmp.utils.feedkeys')
local window = require('cmp.utils.window')
local config = require('cmp.config')
local types = require('cmp.types')
local keymap = require('cmp.utils.keymap')
local api = require('cmp.utils.api')

local SIDE_PADDING = 1

local DEFAULT_HEIGHT = 10 -- @see https://github.com/vim/vim/blob/master/src/popupmenu.c#L45

---@class cmp.CustomEntriesView
---@field private entries_win cmp.Window
---@field private offset number
---@field private active boolean
---@field private entries cmp.Entry[]
---@field private column_width any
---@field public event cmp.Event
local custom_entries_view = {}

custom_entries_view.ns = vim.api.nvim_create_namespace('cmp.view.custom_entries_view')

custom_entries_view.new = function()
  local self = setmetatable({}, { __index = custom_entries_view })
  self.entries_win = window.new()
  self.entries_win:option('conceallevel', 2)
  self.entries_win:option('concealcursor', 'n')
  self.entries_win:option('cursorlineopt', 'line')
  self.entries_win:option('foldenable', false)
  self.entries_win:option('wrap', false)
  self.entries_win:option('scrolloff', 0)
  self.entries_win:option('winhighlight', 'Normal:Pmenu,FloatBorder:Pmenu,CursorLine:PmenuSel,Search:None')
  self.event = event.new()
  self.offset = -1
  self.active = false
  self.entries = {}

  autocmd.subscribe(
    'CompleteChanged',
    vim.schedule_wrap(function()
      if self:visible() and vim.fn.pumvisible() == 1 then
        self:close()
      end
    end)
  )

  vim.api.nvim_set_decoration_provider(custom_entries_view.ns, {
    on_win = function(_, win, buf, top, bot)
      if win ~= self.entries_win.win then
        return
      end

      local fields = config.get().formatting.fields
      for i = top, bot do
        local e = self.entries[i + 1]
        if e then
          local v = e:get_view(self.offset)
          local o = SIDE_PADDING
          local a = 0
          for _, field in ipairs(fields) do
            if field == types.cmp.ItemField.Abbr then
              a = o
            end
            vim.api.nvim_buf_set_extmark(buf, custom_entries_view.ns, i, o, {
              end_line = i,
              end_col = o + v[field].bytes,
              hl_group = v[field].hl_group,
              hl_mode = 'combine',
              ephemeral = true,
            })
            o = o + v[field].bytes + (self.column_width[field] - v[field].width) + 1
          end

          for _, m in ipairs(e.matches or {}) do
            vim.api.nvim_buf_set_extmark(buf, custom_entries_view.ns, i, a + m.word_match_start - 1, {
              end_line = i,
              end_col = a + m.word_match_end,
              hl_group = m.fuzzy and 'CmpItemAbbrMatchFuzzy' or 'CmpItemAbbrMatch',
              hl_mode = 'combine',
              ephemeral = true,
            })
          end
        end
      end
    end,
  })

  return self
end

custom_entries_view.ready = function()
  return vim.fn.pumvisible() == 0
end

custom_entries_view.on_change = function(self)
  self.active = false
end

custom_entries_view.open = function(self, offset, entries)
  self.offset = offset
  self.entries = {}
  self.column_width = { abbr = 0, kind = 0, menu = 0 }

  -- Apply window options (that might be changed) on the custom completion menu.
  self.entries_win:option('winblend', vim.o.pumblend)

  local lines = {}
  local dedup = {}
  local preselect = 0
  local i = 1
  for _, e in ipairs(entries) do
    local view = e:get_view(offset)
    if view.dup == 1 or not dedup[e.completion_item.label] then
      dedup[e.completion_item.label] = true
      self.column_width.abbr = math.max(self.column_width.abbr, view.abbr.width)
      self.column_width.kind = math.max(self.column_width.kind, view.kind.width)
      self.column_width.menu = math.max(self.column_width.menu, view.menu.width)
      table.insert(self.entries, e)
      table.insert(lines, ' ')
      if preselect == 0 and e.completion_item.preselect then
        preselect = i
      end
      i = i + 1
    end
  end
  vim.api.nvim_buf_set_lines(self.entries_win:get_buffer(), 0, -1, false, lines)

  local width = 0
  width = width + 1
  width = width + self.column_width.abbr + (self.column_width.kind > 0 and 1 or 0)
  width = width + self.column_width.kind + (self.column_width.menu > 0 and 1 or 0)
  width = width + self.column_width.menu + 1

  local height = vim.api.nvim_get_option('pumheight')
  height = height ~= 0 and height or #self.entries
  height = math.min(height, #self.entries)

  local pos = api.get_screen_cursor()
  local cursor = api.get_cursor()
  local delta = cursor[2] + 1 - self.offset
  local has_bottom_space = (vim.o.lines - pos[1]) >= DEFAULT_HEIGHT
  local row, col = pos[1], pos[2] - delta - 1

  if not has_bottom_space and math.floor(vim.o.lines * 0.5) <= row and vim.o.lines - row <= height then
    height = math.min(height, row - 1)
    row = row - height - 1
  end
  if math.floor(vim.o.columns * 0.5) <= col and vim.o.columns - col <= width then
    width = math.min(width, vim.o.columns - 1)
    col = vim.o.columns - width - 1
  end

  self.entries_win:open({
    relative = 'editor',
    style = 'minimal',
    row = math.max(0, row),
    col = math.max(0, col),
    width = width,
    height = height,
    zindex = 1001,
  })
  if preselect > 0 and config.get().preselect == types.cmp.PreselectMode.Item then
    self:_select(preselect, { behavior = types.cmp.SelectBehavior.Select })
  elseif not string.match(config.get().completion.completeopt, 'noselect') then
    self:_select(1, { behavior = types.cmp.SelectBehavior.Select })
  else
    self:_select(0, { behavior = types.cmp.SelectBehavior.Select })
  end
end

custom_entries_view.close = function(self)
  self.prefix = nil
  self.offset = -1
  self.active = false
  self.entries = {}
  self.entries_win:close()
end

custom_entries_view.abort = function(self)
  if self.prefix then
    self:_insert(self.prefix)
  end
  feedkeys.call('', 'n', function()
    self:close()
  end)
end

custom_entries_view.draw = function(self)
  local info = vim.fn.getwininfo(self.entries_win.win)[1]
  local topline = info.topline - 1
  local botline = info.topline + info.height - 1
  local texts = {}
  local fields = config.get().formatting.fields
  for i = topline, botline - 1 do
    local e = self.entries[i + 1]
    if e then
      local view = e:get_view(self.offset)
      local text = {}
      table.insert(text, string.rep(' ', SIDE_PADDING))
      for _, field in ipairs(fields) do
        table.insert(text, view[field].text)
        table.insert(text, string.rep(' ', 1 + self.column_width[field] - view[field].width))
      end
      table.insert(text, string.rep(' ', SIDE_PADDING))
      table.insert(texts, table.concat(text, ''))
    end
  end
  vim.api.nvim_buf_set_lines(self.entries_win:get_buffer(), topline, botline, false, texts)

  if api.is_cmdline_mode() then
    vim.api.nvim_win_call(self.entries_win.win, function()
      vim.cmd([[redraw]])
    end)
  end
end

custom_entries_view.visible = function(self)
  return self.entries_win:visible()
end

custom_entries_view.info = function(self)
  return self.entries_win:info()
end

custom_entries_view.select_next_item = function(self, option)
  if self:visible() then
    local cursor = vim.api.nvim_win_get_cursor(self.entries_win.win)[1] + 1
    if not self.entries_win:option('cursorline') then
      cursor = 1
    elseif #self.entries < cursor then
      cursor = 0
    end
    self:_select(cursor, option)
  end
end

custom_entries_view.select_prev_item = function(self, option)
  if self:visible() then
    local cursor = vim.api.nvim_win_get_cursor(self.entries_win.win)[1] - 1
    if not self.entries_win:option('cursorline') then
      cursor = #self.entries
    end
    self:_select(cursor, option)
  end
end

custom_entries_view.get_first_entry = function(self)
  if self:visible() then
    return self.entries[1]
  end
end

custom_entries_view.get_selected_entry = function(self)
  if self:visible() and self.entries_win:option('cursorline') then
    return self.entries[vim.api.nvim_win_get_cursor(self.entries_win.win)[1]]
  end
end

custom_entries_view.get_active_entry = function(self)
  if self:visible() and self.active then
    return self:get_selected_entry()
  end
end

custom_entries_view._select = function(self, cursor, option)
  local is_insert = (option.behavior or types.cmp.SelectBehavior.Insert) == types.cmp.SelectBehavior.Insert
  if is_insert and not self.active then
    self.prefix = string.sub(api.get_current_line(), self.offset, api.get_cursor()[2]) or ''
  end

  self.active = cursor > 0 and is_insert
  self.entries_win:option('cursorline', cursor > 0)
  vim.api.nvim_win_set_cursor(self.entries_win.win, { math.max(cursor, 1), 0 })

  if is_insert then
    self:_insert(self.entries[cursor] and self.entries[cursor]:get_vim_item(self.offset).word or self.prefix)
  end

  self.entries_win:update()
  self:draw()
  self.event:emit('change')
end

custom_entries_view._insert = setmetatable({
  pending = false,
}, {
  __call = function(this, self, word)
    word = word or ''
    if api.is_cmdline_mode() then
      local cursor = api.get_cursor()
      local length = vim.str_utfindex(string.sub(api.get_current_line(), self.offset, cursor[2]))
      vim.api.nvim_feedkeys(keymap.backspace(length) .. word, 'int', true)
    else
      if this.pending then
        return
      end
      this.pending = true

      local release = require('cmp').suspend()
      feedkeys.call('', '', function()
        local cursor = api.get_cursor()
        feedkeys.call(
          keymap.backspace(1 + cursor[2] - self.offset) .. word,
          'int',
          vim.schedule_wrap(function()
            this.pending = false
            release()
          end)
        )
      end)
    end
  end,
})

return custom_entries_view
