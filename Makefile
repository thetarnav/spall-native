.PHONY: release, opt, build

all: build

release:
	odin build src -collection:formats=formats -out:bin/spall -debug -o:speed -no-bounds-check -define:GL_DEBUG=false -strict-style -minimum-os-version:11.0

opt:
	odin build src -collection:formats=formats -out:bin/spall -debug -o:speed -strict-style -minimum-os-version:11.0

build:
	odin build src -collection:formats=formats -out:bin/spall -debug -strict-style -minimum-os-version:11.0
