.PHONY: build clean

build:
	swift build
	mkdir -p dist
	cp .build/debug/breath .build/debug/breath-debug dist/

clean:
	rm -rf .build dist
