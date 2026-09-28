.PHONY: test test-lua test-node test-e2e demo

test: test-lua test-node

test-lua:
	./tests/run.sh

test-node:
	cd tests/node && npm install --silent --no-audit --no-fund && node --test

# Live end-to-end run against the installed agent CLIs (not part of `make test`); see tests/e2e/run.sh.
test-e2e:
	./tests/e2e/run.sh $(AGENTS)

# Re-record the README demo (demo/agent-nvim-demo.gif) with VHS; it fetches nvim-gdb, so it needs
# network access (see demo/record.sh).
demo:
	./demo/record.sh
