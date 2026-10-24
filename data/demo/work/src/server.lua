local config = require("sundial.config")

local function serve(settings)
    local settings = settings or config.load_config("sundial.toml")
    local http = require("sundial.http")

    -- Re-render the changed page before each request instead of rebuilding
    -- the whole site when watch mode is on.
    local index = require("sundial.pages").load(settings.source)

    local ok, err = pcall(function()
        http.listen(settings.port, index)
    end)
    if not ok then
        error("could not start the server: " .. tostring(err))
    end
end

return { serve = serve }
