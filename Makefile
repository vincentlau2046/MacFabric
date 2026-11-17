# MacFabric 一键验证（次级 1：测试基建 · spec 2026-11-17-batch4-jobs-infra.md）
# 全链 = App 契约测试 + 网关 pytest + 双档构建
PYTHON ?= .venv/bin/python

.PHONY: test test-py test-contract build smoke clean

test: test-contract test-py build
	@echo "ALL_GREEN: 契约 + pytest + 双档构建 全过"

test-contract:
	bash scripts/test-app-contracts.sh

test-py:
	cd macfabric_gateway && ../$(PYTHON) -m pytest tests/ -q

build:
	bash macfabric-app/build.sh --debug
	bash macfabric-app/build.sh

smoke:
	bash scripts/release-install.sh

clean:
	rm -rf build/tmp
