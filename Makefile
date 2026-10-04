# Makefile — 便捷入口（逻辑都在 build.sh）
.PHONY: all package fetch stage verify deb clean distclean info repro check arm64 aarch64 amd64 e2e

all: package

package:
	./build.sh

fetch:
	./build.sh fetch

stage:
	./build.sh stage

verify:
	./build.sh verify

deb:
	./build.sh deb

clean:
	./build.sh clean

distclean:
	./build.sh distclean

info:
	./build.sh info

# V6 可复现构建配方（审核材料速查）
repro:
	./build.sh repro

# 语法与静态自检
check:
	sh -n makedeb.sh
	bash -n build.sh
	bash -n test/install-and-verify.sh
	for f in preinst postinst prerm postrm; do bash -n "assets/$$f"; done
	python3 -c "import json; json.load(open('assets/config.ini.in'))"
	python3 -c "import xml.etree.ElementTree as ET; ET.parse('assets/images/icons/mediamtx.svg'); print('icon ok')"
	@echo "语法检查通过"

arm64:
	TARGET_ARCH=arm64 ./build.sh
aarch64: arm64
amd64:
	TARGET_ARCH=amd64 ./build.sh

# 真机 E2E（需设 TEST_TARGET，如 TEST_TARGET=apple@<nas> make e2e）
e2e:
	./test/install-and-verify.sh
