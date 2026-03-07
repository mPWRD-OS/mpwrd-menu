# mpwrd-menu

Lightweight TUI for mPWRD-OS.

## Overview

`mpwrd-menu` is a lightweight Bash menu for minimal console images. It provides:

- `Contact`
- `Meshtastic Related Services`
- `meshtasticd Repository`
- `Mesh Apps Manager`
- `Network Quick Start`
- `Board Config`

## Files

- `mpwrd-menu`: Main TUI script
- `mesh-apps.conf`: App list for the Mesh Apps Manager
- `mesh-services.conf`: Service list for Meshtastic Related Services

## Install

```bash
git clone https://github.com/mPWRD-OS/mpwrd-menu.git
cd mpwrd-menu
chmod +x mpwrd-menu
```

## Debian Package

Use this Deb822 source file for the published APT repo:

```deb822
Types: deb
URIs: https://mpwrd-os.github.io/mpwrd-menu
Suites: testing
Components: main
Architectures: all
Signed-By: /etc/apt/keyrings/mpwrd-archive-keyring.gpg
```

Install from the testing channel:

```bash
sudo install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://mpwrd-os.github.io/mpwrd-menu/mpwrd-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/mpwrd-archive-keyring.gpg > /dev/null

sudo tee /etc/apt/sources.list.d/mpwrd-menu.sources > /dev/null <<'EOF'
Types: deb
URIs: https://mpwrd-os.github.io/mpwrd-menu
Suites: testing
Components: main
Architectures: all
Signed-By: /etc/apt/keyrings/mpwrd-archive-keyring.gpg
EOF

sudo apt update
sudo apt install mpwrd-menu
```

## Run

```bash
./mpwrd-menu
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
