.PHONY: dev

PYTHON ?= python3

dev:
	portless run --name lokalbot $(PYTHON) Scripts/serve-web.py
