local config = require("sundial.config")

local function build(settings)
    local pages = require("sundial.pages")
    local rendered = pages.render(settings.source)

    local out = require("sundial.output")
    out.write_all(rendered, settings.output)

    return ("%d page(s) written to %s"):format(#rendered, settings.output)
end

local function main(args)
    local settings = config.load_config(args.config or "sundial.toml")

    if args.command == "serve" then
        return require("sundial.server").serve(settings)
    elseif args.command == "build" then
        print(build(settings))
    else
        error("unknown command: " .. tostring(args.command))
    end
end

return { main = main }
