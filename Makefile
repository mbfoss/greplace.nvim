# Unit tests run under busted, with nlua as the interpreter so that the specs
# execute inside Neovim and can use the `vim` API.
#
# busted and nlua are installed into a project-local luarocks tree (.luarocks,
# gitignored) the first time `make test` runs, so nothing needs setting up by
# hand.  Extra busted flags can be passed through, e.g.:
#
#     make test BUSTED_ARGS="--filter=panel -o gtest"

LUA_VERSION = 5.1
TREE        = $(CURDIR)/.luarocks
LUAROCKS    = luarocks --lua-version=$(LUA_VERSION) --tree=$(TREE)
BUSTED      = $(TREE)/bin/busted

.PHONY: all
all:test

.PHONY: unit_test
unit_test: deps
	@# stdin is closed: nlua would otherwise read from it when it is not a tty.
	@eval "$$($(LUAROCKS) path)" && \
	PATH="$(TREE)/bin:$$PATH" $(BUSTED) $(BUSTED_ARGS) </dev/null

.PHONY: deps
deps: $(BUSTED)

$(BUSTED):
	$(LUAROCKS) install busted
	$(LUAROCKS) install nlua

.PHONY: clean-deps
clean-deps:
	rm -rf $(TREE)

.PHONY: test
test: unit_test

