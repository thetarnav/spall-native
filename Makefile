.PHONY: release, debug, run, check

ODIN ?= odin

VET_FLAGS =   -strict-style         \
              -warnings-as-errors   \
              -vet-unused           \
              -vet-unused-variables \
              -vet-unused-imports

COLLECTION =  -collection:formats=formats

BUILD_FLAGS = -out:bin/spall           \
              -minimum-os-version:11.0

# Arguments after --
EXTRA_FLAGS = $(filter-out $@,$(MAKECMDGOALS))

all: run

release:
	$(ODIN) build src $(BUILD_FLAGS) $(COLLECTION) $(VET_FLAGS) $(EXTRA_FLAGS) \
		-o:speed         \
		-disable-assert  \
		-no-bounds-check

debug:
	$(ODIN) build src $(BUILD_FLAGS) $(COLLECTION) $(EXTRA_FLAGS) \
		-debug

run:
	$(ODIN) run src $(BUILD_FLAGS) $(COLLECTION) $(EXTRA_FLAGS)

check:
	$(ODIN) check src $(COLLECTION) $(VET_FLAGS) $(EXTRA_FLAGS) -target:linux_amd64
	$(ODIN) check src $(COLLECTION) $(VET_FLAGS) $(EXTRA_FLAGS) -target:darwin_amd64
	$(ODIN) check src $(COLLECTION) $(VET_FLAGS) $(EXTRA_FLAGS) -target:windows_amd64

# Prevent make from trying to build files named after extra flags
%:
	@:
