# VPS-Traffic-Tunnel — developer tasks
SHELLCHECK ?= shellcheck
SHELL_FILES := vt $(wildcard lib/*.sh) $(wildcard tests/*.sh)

.PHONY: help test lint syntax install uninstall clean

help:
	@echo "make test      — run the full check suite (syntax, shellcheck, unit, e2e dry-run installs)"
	@echo "make lint      — shellcheck over vt, lib/ and tests/"
	@echo "make syntax    — bash -n over every shell file"
	@echo "make install   — put the program in /opt/vt and 'vt' on PATH (needs root)"
	@echo "make clean     — remove editor/temp noise"

test:
	./tests/run_tests.sh

lint:
	$(SHELLCHECK) -x -s bash $(SHELL_FILES)

syntax:
	@for f in $(SHELL_FILES); do bash -n $$f || exit 1; done
	@echo "syntax OK"

install:
	sudo ./vt self-install

uninstall:
	sudo ./vt uninstall

clean:
	rm -rf .vt-unit-test dist
	find . -name '*.orig' -o -name '*.rej' -o -name '*~' | xargs -r rm -f
