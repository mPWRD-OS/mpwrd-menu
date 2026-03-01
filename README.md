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
- `mesh-apps.conf.example`: Example app list for the Mesh Apps Manager

## Install

```bash
git clone https://github.com/Ruledo/mpwrd-menu.git
cd mpwrd-menu
chmod +x mpwrd-menu.sh
```

Optional local app list override:

```bash
cp mesh-apps.conf.example mesh-apps.conf
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
- `Mesh Apps Manager` reads `mesh-apps.conf` first, then falls back to `mesh-apps.conf.example`.
- Board configs are copied from `/etc/meshtasticd/available.d/` into `/etc/meshtasticd/config.d/`.
