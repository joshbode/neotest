local async = require("plenary.async")
local consumer_name = "neotest-output"
local lib = require("neotest.lib")
local config = require("neotest.config")

local win

local function open_output(result, opts)
  local buf = async.api.nvim_create_buf(false, true)
  local chan = async.api.nvim_open_term(buf, {})
  local output = opts.short and result.short or lib.files.read(result.output)
  -- See https://github.com/neovim/neovim/issues/14557
  local dos_newlines = string.find(output, "\r\n") ~= nil
  async.api.nvim_chan_send(chan, dos_newlines and output or output:gsub("\n", "\r\n"))
  async.util.sleep(10) -- Wait for chan to send
  local lines = async.api.nvim_buf_get_lines(buf, 0, -1, false)
  local width, height = 80, #lines
  for _, line in pairs(lines) do
    local line_length = vim.str_utfindex(line)
    if line_length > width then
      width = line_length
    end
  end

  win = lib.ui.float.open({
    width = width,
    height = height,
    buffer = buf,
    enter = opts.enter,
  })
  async.api.nvim_buf_set_keymap(
    buf,
    "n",
    "q",
    "<cmd>lua pcall(vim.api.nvim_win_close, " .. win.win_id .. ", true)<CR>",
    { noremap = true, silent = true }
  )
  win:listen("close", function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.fn.chanclose, chan)
    win = nil
  end)
end

---@param client NeotestClient
return function(client)
  if config.output.open_on_run then
    client.listeners.results[consumer_name] = function(results)
      local cur_pos = async.fn.getpos(".")
      local line = cur_pos[2] - 1
      local buf_path = vim.fn.expand("%:p")
      local positions = client:get_position(buf_path)
      if not positions then
        return
      end
      for _, pos in positions:iter() do
        if
          pos.type == "test"
          and results[pos.id]
          and results[pos.id].status == "failed"
          and pos.range[1] <= line
          and pos.range[3] >= line
        then
          open_output(
            results[pos.id],
            { enter = false, short = config.output.open_on_run == "short" }
          )
        end
      end
    end
  end
  return {
    open = function(opts)
      opts = opts or {}
      if win then
        if pcall(win.jump_to, win) then
          return
        end
        opts.enter = true
      end
      async.run(function()
        local tree, adapter_id
        if not opts.position_id then
          local file_path = vim.fn.expand("%:p")
          local row = vim.fn.getbufinfo(file_path)[1].lnum - 1
          tree, adapter_id = client:get_nearest(file_path, row)
        else
          tree, adapter_id = client:get_position(opts.position_id)
        end
        if not tree then
          lib.notify("No tests found in file", "warn")
          return
        end
        local result = client:get_results(adapter_id)[tree:data().id]
        if not result then
          lib.notify("No output for " .. tree:data().name)
          return
        end
        open_output(result, opts)
      end)
    end,
  }
end