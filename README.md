# PortWatch

A small macOS menu-bar app that lists every TCP port something on your Mac is listening on, with the process, PID and project folder. Stop or kill your own processes, or open `http://localhost:<port>` in the browser.

- **Search:** filter by port, process name, PID or folder. Every word must match (`node 30` finds node on port 3000). Cmd+F focuses the field, Esc clears it.
- Refreshes every 3 seconds; the menu-bar count shows how many ports are open.
- Only your own processes can be stopped. It uses `lsof`; no privileges needed.

## Build and run

    ./build.sh          # builds ~/Applications/PortWatch.app (needs Xcode command line tools)
    open ~/Applications/PortWatch.app

The app is ad-hoc signed, so on first launch right-click it and choose Open.
