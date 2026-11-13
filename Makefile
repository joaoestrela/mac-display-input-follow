BINDIR  ?= $(HOME)/.local/bin
LABEL   ?= com.joaoestrela.display-follow
PLIST   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG     := $(HOME)/Library/Logs/display-follow.log
DOMAIN  := gui/$(shell id -u)
BUILD   := .build
BIN     := $(BUILD)/display-follow
CORE    := $(wildcard Sources/DisplayFollowCore/*.swift)
SWIFTC  ?= swiftc
# Module cache inside the build dir, so sandboxed builds (Homebrew) don't write to ~/Library/Caches.
SWIFTFLAGS ?= -O -swift-version 5 -target arm64-apple-macos13 -module-cache-path $(BUILD)/module-cache

.PHONY: build check install uninstall start stop restart logs clean

build: $(BIN)

# Plain swiftc: core sources and the entry point compile into one module.
$(BIN): $(CORE) Sources/display-follow/main.swift
	@mkdir -p $(BUILD)
	$(SWIFTC) $(SWIFTFLAGS) -module-name DisplayFollow -o $@ $^

$(BUILD)/selfcheck: $(CORE) Sources/selfcheck/main.swift
	@mkdir -p $(BUILD)
	$(SWIFTC) $(SWIFTFLAGS) -module-name SelfCheck -o $@ $^

check: $(BUILD)/selfcheck
	$(BUILD)/selfcheck

install: build
	install -d $(BINDIR) $(HOME)/Library/LaunchAgents $(HOME)/Library/Logs
	install -m 755 $(BIN) $(BINDIR)/display-follow
	rm -f $(BINDIR)/extdisplay
	sed -e 's#@LABEL@#$(LABEL)#' -e 's#@BINDIR@#$(BINDIR)#' -e 's#@LOG@#$(LOG)#' \
	    launchd/com.display-follow.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	@$(BINDIR)/display-follow status >/dev/null 2>&1 || $(BINDIR)/display-follow setup
	$(MAKE) restart

start:
	launchctl bootstrap $(DOMAIN) $(PLIST)

# bootout returns before launchd has unloaded the job; a bootstrap right after it fails with error 5.
stop:
	-launchctl bootout $(DOMAIN)/$(LABEL)
	@for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print $(DOMAIN)/$(LABEL) >/dev/null 2>&1 || exit 0; sleep 0.5; done

restart: stop start

uninstall: stop
	rm -f $(PLIST) $(BINDIR)/display-follow $(BINDIR)/extdisplay
	rm -rf $(HOME)/.local/share/display-follow

logs:
	tail -f $(LOG)

clean:
	rm -rf $(BUILD)
