.PHONY: test syntax build build-ss build-xray

syntax:
	bash -n ssctl.sh bootstrap.sh build-core.sh tests/test_manager.sh
	python3 -m py_compile lib/ssctl.py

test: syntax
	tests/test_manager.sh

build:
	./build-core.sh --core all --arch native --libc glibc

build-ss:
	./build-core.sh --core ss --arch native --libc glibc

build-xray:
	./build-core.sh --core xray --arch native --libc glibc
