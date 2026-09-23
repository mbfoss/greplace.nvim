---@brief Health check for greplace.nvim - run with `:checkhealth greplace`.
---
---Reports the Neovim version, ripgrep, the commands, and the options that
---differ from the defaults. `setup()` is optional, so the config is reported
---either way.

local M = {}

local health = vim.health

---Check the Neovim version against the plugin's minimum (see
---`plugin/greplace.lua`). Silent on a supported version: a health check is for
---what is wrong, not for what is unremarkable.
local function _check_requirements()
    if vim.fn.has("nvim-0.11") ~= 1 then
        health.start("greplace: requirements")
        health.error("greplace.nvim requires Neovim >= 0.11")
    end
end

---ripgrep is the search itself: without it `:Gsearch` has nothing to run, and
---the only report of that is an error at search time. Its version is shown
---because the JSON output the plugin parses is `rg`'s own format.
local function _check_ripgrep()
    health.start("greplace: ripgrep")

    if vim.fn.executable("rg") ~= 1 then
        health.error("ripgrep (rg) was not found on $PATH", {
            "greplace searches with rg; install it from https://github.com/BurntSushi/ripgrep",
        })
        return
    end

    local ok, res = pcall(function()
        return vim.system({ "rg", "--version" }, { text = true }):wait(5000)
    end)
    local version = ok and res.code == 0
        and vim.trim(vim.split(res.stdout or "", "\n")[1] or "")
        or nil
    if version and version ~= "" then
        health.ok(version .. " (" .. vim.fn.exepath("rg") .. ")")
    else
        -- On $PATH but not answering: a wrapper script, a broken install.
        health.warn("rg is on $PATH but `rg --version` did not report one", {
            "Check that `rg --version` runs in a shell",
        })
    end
end

---The commands come from `plugin/greplace.lua`, so they exist without a
---`setup()`; their absence means the plugin directory was not loaded.
local function _check_commands()
    health.start("greplace: commands")

    for _, name in ipairs({ "Gsearch", "Greplace" }) do
        if vim.fn.exists(":" .. name) == 2 then
            health.ok((":%s is registered"):format(name))
        else
            health.error((":%s is not registered"):format(name), {
                "plugin/greplace.lua did not run; check the plugin is on the runtimepath",
            })
        end
    end
end

---Collect the options whose value differs from the default, as flat paths with
---the value now in force. Lists are compared whole rather than descended into:
---a list-valued option is one option, not one option per element.
---@param current table
---@param defaults table
---@param prefix string  path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
    for key, value in pairs(current) do
        local path = prefix .. tostring(key)
        local default = defaults[key]
        if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
            _diff_config(value, default, path .. ".", out)
        elseif not vim.deep_equal(value, default) then
            table.insert(out, {
                path    = path,
                value   = vim.inspect(value, { newline = " ", indent = "" }),
                unknown = default == nil,
            })
        end
    end
    return out
end

---Report the options that differ from the defaults - the whole config would be
---mostly untouched defaults, and the point here is what this user changed.
---Anything set that the plugin does not define is flagged: `setup()` merges
---`opts` wholesale, so a misspelled option is kept silently.
local function _check_config()
    health.start("greplace: configuration")

    local config = require("greplace.config")
    local diffs  = _diff_config(config.current, config.defaults(), "", {})
    table.sort(diffs, function(a, b) return a.path < b.path end)

    if #diffs == 0 then
        health.ok("every option is at its default")
        return
    end

    local lines = {}
    for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
    end
    health.ok(("%d option%s differ%s from the defaults:\n%s")
        :format(#diffs, #diffs == 1 and "" or "s", #diffs == 1 and "s" or "",
            table.concat(lines, "\n")))

    for _, entry in ipairs(diffs) do
        if entry.unknown then
            health.warn(("`%s` is not an option greplace defines"):format(entry.path), {
                "Check its spelling against the options listed in the README",
            })
        end
    end
end

function M.check()
    _check_requirements()
    _check_ripgrep()
    _check_commands()
    _check_config()
end

return M
