# MacFabric 一键验证（M1 起：网关单线；App 线已删除，D17 裁决 2026-11-18）
PYTHON ?= .venv/bin/python

.PHONY: test test-py smoke clean

test: test-py
	@echo "ALL_GREEN: gateway pytest 全过"

test-py:
	cd macfabric_gateway && ../$(PYTHON) -m pytest tests/ -q

smoke:
	bash scripts/release-install.sh

clean:
	rm -rf build/tmp
