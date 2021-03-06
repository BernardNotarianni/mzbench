RUN_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
SECOND_ARG := $(wordlist 2,2,$(MAKECMDGOALS))

.SILENT: new-worker

REBAR := $(abspath $(shell which ../bin/rebar3 || which rebar3))
SERVICE_PREFIX=/mz
SERVICE_NAME=mzbench
SERVICE_LOG_DIR=/var/log/${SERVICE_NAME}
GIT_HEAD := $(shell git rev-parse HEAD)
OS_VERSION := $(shell uname -sr | awk '{gsub(/ /, "-"); print tolower($$0)}')
RELEASE_BINARY := _build/default/rel/$(SERVICE_NAME)/bin/$(SERVICE_NAME)

# all files not in ebin or .eunit
SOURCES := $(shell find apps -name .eunit -prune -o -name ebin -prune -o -type f -print)
MZBENCH_COMMON_SOURCES := $(wildcard ../common_apps/*/include/*) $(wildcard ../common_apps/*/src/*) $(wildcard ../common_apps/*/rebar.config)

.PHONY: compile
compile: .make/compilation-up-to-date

.PHONY: run
run: compile
	./scripts/run_local.escript $(realpath $(SECOND_ARG))

.PHONY: generate
generate: $(RELEASE_BINARY)

.PHONY: console
console: $(RELEASE_BINARY)
	$@ console $(realpath $(RUN_ARGS))

.PHONY: $(SECOND_ARG)
$(SECOND_ARG):
	@true

.PHONY: test-unit
test-unit: compile
	$(REBAR) eunit skip_deps=true

.PHONY: check
check: test-unit dialyzer.log

.PHONY: install
install: generate
	mkdir -p ~/.local/share/mz
	cp -rf _build/default/rel/mzbench ~/.local/share/

.PHONY: generate_tgz
generate_tgz: generate
	mkdir -p pkgroot
	cp -rf _build/default/rel/mzbench pkgroot/
	cd pkgroot && tar czf ../node.tgz ./mzbench && cd ..
	rm -rf pkgroot

.PHONY: local_tgz
local_tgz: ERTS_VSN := $(shell erl -noshell -eval 'io:fwrite("~s", [erlang:system_info(version)]).' -s erlang halt)
local_tgz: generate_tgz
	mkdir -p ~/.local/cache/mzbench_api/packages
	cp node.tgz ~/.local/cache/mzbench_api/packages/node-$(GIT_HEAD)-$(OS_VERSION)_erts-$(ERTS_VSN).tgz

.PHONY: clean
clean:
	$(REBAR) clean
	rm -rf _build
	rm -rf .make
	rm -rf *.tgz
	rm -rf pkgroot

DIALYZABLE_EBINS := apps/*/ebin
-include ../lib/dialyzer.mk

$(RELEASE_BINARY): .make/compilation-up-to-date rel/files/sys.config rel/files/vm.args
	$(REBAR) release
	touch $(RELEASE_BINARY)

.make/compilation-up-to-date: rebar.config $(SOURCES) .make/git-rev-$(GIT_HEAD) $(MZBENCH_COMMON_SOURCES)
	$(REBAR) compile
	make -C _build/default/deps/jiffy
	mkdir -p .make && touch $@

.make/git-rev-$(GIT_HEAD):
	rm -rf .make/git-rev-*
	mkdir -p .make && touch $@

