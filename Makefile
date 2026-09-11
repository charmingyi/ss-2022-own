.PHONY: test syntax build build-ss build-xray package-release

syntax:
	bash -n ssctl.sh bootstrap.sh build-core.sh package-release.sh tests/test_manager.sh tests/test_menu.sh
	python3 -m py_compile lib/ssctl.py

test: syntax
	tests/test_manager.sh
	tests/test_menu.sh

build:
	./build-core.sh --core all --arch native --libc glibc

build-ss:
	./build-core.sh --core ss --arch native --libc glibc

build-xray:
	./build-core.sh --core xray --arch native --libc glibc

package-release:
	./package-release.sh
