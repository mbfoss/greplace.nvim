TESTS_INIT=tests/init.lua
TESTS_DIR=tests/

.PHONY: all
all:test

.PHONY: unit_test
unit_test:
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { init = '${TESTS_INIT}' }"

.PHONY: test
test: unit_test

