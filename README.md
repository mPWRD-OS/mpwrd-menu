# mpwrd-menu

Lightweight TUI for mPWRD-OS.

## Overview

`mpwrd-menu.sh` is a dependency-free Bash menu for minimal console images. It provides:

- `Contact`
- `Meshtastic Related Services`
- `meshtasticd Repository`
- `Mesh Apps Manager`
- `Network Quick Start`
- `Board Config`

## Files

- `mpwrd-menu.sh`: Main TUI script
- `mesh-apps.conf`: App list for the Mesh Apps Manager
- `mesh-services.conf`: Service list for Meshtastic Related Services

## Install

```bash
git clone https://github.com/mPWRD-OS/mpwrd-menu.git
cd mpwrd-menu
chmod +x mpwrd-menu.sh
```

## Run

```bash
./mpwrd-menu.sh
```

## Notes

- The TUI itself uses Bash only.
- Some actions rely on system tools already expected on the target OS, such as `systemctl`, `apt-get`, `nmtui`, `pipx`, `curl` or `wget`, `gpg`, and `sudo`.
- `Network Quick Start` runs `nmtui` and returns directly to the menu when finished.
- `Contact` in the main menu runs the `contact` command directly.
- `Mesh Apps Manager` reads `mesh-apps.conf`.
- App manager types supported in `mesh-apps.conf` are `apt`, `pipx`, and `pipx-global`.
- `Meshtastic Related Services` reads `mesh-services.conf`.
- Board configs are copied from `/etc/meshtasticd/available.d/` into `/etc/meshtasticd/config.d/`.
