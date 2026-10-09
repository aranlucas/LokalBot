.PHONY: dev dev-direct

PYTHON ?= python3

dev:
	portless run --name lokalbot $(PYTHON) Scripts/serve-web.py

dev-direct:
	$(PYTHON) Scripts/serve-web.py
