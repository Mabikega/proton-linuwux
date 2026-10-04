## Package updates

GitHub Actions checks for upstream releases once a day at 00:17 UTC and builds
package versions missing from the repository release. Pushes do not start builds.
Use the workflow's manual trigger to check immediately, or enable `force` to
rebuild packages already published.

## Add the repository

Add this before the CachyOS repositories
in `/etc/pacman.conf`:

```ini
[linuwux]
SigLevel = Optional
Server = https://github.com/Mabikega/proton-linuwux/releases/download/packages
```

Refresh the package databases:

```sh
sudo pacman -Syu
```

## Install and load the module

Install the headers for the running kernel, then run:

```sh
sudo pacman -S umip-limit-fix-linuwux-dkms
sudo modprobe umip_limit_fix_linuwux
```

## Load the module automatically at boot

```sh
printf '%s\n' umip_limit_fix_linuwux | sudo tee /etc/modules-load.d/umip_limit_fix_linuwux.conf
sudo modprobe umip_limit_fix_linuwux
```
