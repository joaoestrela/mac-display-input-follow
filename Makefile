BINDIR  ?= $(HOME)/.local/bin
LABEL   ?= com.joaoestrela.display-follow
PLIST   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG     := $(HOME)/Library/Logs/display-follow.log
DOMAIN  := gui/$(shell id -u)

.PHONY: build install uninstall start stop restart logs clean

build: build/extdisplay

build/extdisplay: src/extdisplay.swift
	@mkdir -p build
	swiftc -O -o $@ $<

install: build
	install -d $(BINDIR) $(HOME)/Library/LaunchAgents $(HOME)/Library/Logs
	install -m 755 build/extdisplay bin/display-follow $(BINDIR)/
	sed -e 's#@LABEL@#$(LABEL)#' -e 's#@BINDIR@#$(BINDIR)#' -e 's#@LOG@#$(LOG)#' \
	    launchd/com.display-follow.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	$(MAKE) restart

start:
	launchctl bootstrap $(DOMAIN) $(PLIST)

stop:
	-launchctl bootout $(DOMAIN)/$(LABEL)

restart: stop start

uninstall: stop
	rm -f $(PLIST) $(BINDIR)/display-follow $(BINDIR)/extdisplay
	rm -rf $(HOME)/.local/share/display-follow

logs:
	tail -f $(LOG)

clean:
	rm -rf build
