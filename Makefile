# chicago/aicq — lint and test on the runtime fork's build.

# pipefail lets the test target both stream runner output and keep its exit
# code while grepping the log afterwards.
SHELL := bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: lint test icons

# The shell this module runs in declares entries with the `gfx` module, and
# only the runtime fork has it (chicago-desktop/runtime, a build from its
# releases, v0.3.40a-chicago.2 or newer — the one that also resolves the
# shell and the base from their GitHub repositories by tag): the release
# `wippy` does not load such a module at all ("node with ID … not found").
# Point WIPPY at the fork's binary:
#
#   make test WIPPY=~/src/runtime/dist/wippy-linux-amd64
WIPPY ?= $(CURDIR)/../runtime/dist/wippy-linux-amd64

# The shell declares its own terminal.host, and the CLI then refuses to pick
# one by itself; the suites run on the application's ordinary host.
TEST_HOST := wippy.terminal:host

# Late `local`s first — a local read above its declaration is a global, that
# is nil, with no error; `wippy lint` does not see this at all.
lint:
	python3 tools/late-locals.py src
	python3 tools/late-locals.py test/src
	$(WIPPY) lint

# The runner exits 0 when it discovers no tests, which would turn a broken
# discovery into a green run, so an empty discovery fails here.
test:
	mkdir -p test/.wippy
	cd test && $(WIPPY) test --host $(TEST_HOST) 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log

# Redraw the image pack (assets/images/{32,16}/*.png).
icons:
	python3 tools/chat_icons.py
