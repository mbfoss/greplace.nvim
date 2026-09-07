# Unit tests run under busted, with `tests/nvim-lua` (the interpreter shim named
# by `.busted`) so that the specs execute inside Neovim and can use the `vim`
# API. busted therefore has to be installed for Lua $(LUA_VERSION), the version
# Neovim embeds; nothing else is needed:
#
#     luarocks --lua-version=$(LUA_VERSION) --local install busted
#
# `make test` fails if it is missing; it never installs anything itself.
# Extra busted flags can be passed through, e.g.:
#
#     make test BUSTED_ARGS="--filter=panel -o gtest"

LUA_VERSION = 5.1
LUAROCKS    = luarocks --lua-version=$(LUA_VERSION)

.PHONY: all
all: test

.PHONY: unit_test
unit_test: deps
	@# stdin is closed: Neovim would otherwise read from it when it is not a tty.
	@eval "$$($(LUAROCKS) path)" && busted $(BUSTED_ARGS) </dev/null

.PHONY: deps
deps:
	@$(LUAROCKS) show busted >/dev/null 2>&1 || \
		{ echo "busted is not installed for Lua $(LUA_VERSION): $(LUAROCKS) --local install busted" >&2; exit 1; }
	@command -v $${NVIM:-nvim} >/dev/null 2>&1 || \
		{ echo "$${NVIM:-nvim} not found in PATH" >&2; exit 1; }

.PHONY: test
test: unit_test
