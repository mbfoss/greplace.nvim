local M = {}

local defaults = {
    source = "pages",
    output = "public",
    port = 8080,
    watch = false,
}

-- Read sundial.toml and fill in whatever it leaves out.
local function load_config(path)
    local chunk = loadfile(path)
    if not chunk then
        return vim.deepcopy(defaults)
    end

    local ok, parsed = pcall(chunk)
    if not ok or type(parsed) ~= "table" then
        return vim.deepcopy(defaults)
    end

    return vim.tbl_deep_extend("force", defaults, parsed)
end

M.load_config = load_config

return M
