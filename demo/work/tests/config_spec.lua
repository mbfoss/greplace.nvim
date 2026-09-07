local config = require("sundial.config")

describe("load_config", function()
    it("fills in the defaults", function()
        local settings = config.load_config("tests/fixtures/empty.toml")

        assert.are.equal("pages", settings.source)
        assert.are.equal("public", settings.output)
        assert.are.equal(8080, settings.port)
        assert.is_false(settings.watch)
    end)

    it("keeps the values the file sets", function()
        local settings = config.load_config("tests/fixtures/site.toml")

        assert.are.equal(9000, settings.port)
        assert.is_true(settings.watch)
    end)
end)
