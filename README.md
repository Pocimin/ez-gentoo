# ez gentoo

One-click Gentoo VM installer and launcher for Windows Hyper-V.

`ez gentoo` is for people who want to play with Gentoo, flex `neofetch`, open a real Linux desktop, and learn without doing the whole manual install ritual on day one.

## What It Does

- creates a Hyper-V VM
- imports a prepared Gentoo desktop image
- starts the VM
- finds the VM's changing Hyper-V IP automatically
- waits for VNC
- opens TigerVNC fullscreen
- gives you a small Windows launcher UI

## Quick Start

Run PowerShell as Administrator:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ez-gentoo.ps1
```

Then click **Install / Start**.

The launcher can use either:

- a prepared `ez-gentoo-base.vhdx` release asset
- a local `.vhdx` file
- a local `.qcow2` file, converted with `qemu-img`

## Requirements

- Windows 10/11 Pro, Enterprise, or Education
- Hyper-V enabled
- virtualization enabled in BIOS/UEFI
- PowerShell 5+
- TigerVNC Viewer
- `qemu-img` if installing from `.qcow2`

The launcher can install TigerVNC and qemu-img through `winget` when available.

## Why A Prepared Image?

Gentoo is source-based. A fully manual desktop install can take hours on a small laptop. This project ships the fun path: a prepared Gentoo desktop image plus a launcher. You still get real Gentoo, Portage, XFCE, terminal, Firefox, and the ability to compile stuff when you want.

The VM image is intentionally not committed to git. Put it on GitHub Releases as:

```text
ez-gentoo-base.vhdx
```

## Making A Release Image

After preparing a VM named `GentooReady`, run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\export-current-vm.ps1 -VmName GentooReady
```

Upload the generated `.zip` or `.vhdx` from `dist/` to a GitHub Release.

## Guest Defaults

The prepared image should provide:

- user: `reina` or your preferred demo user
- VNC display: `:1`
- VNC TCP port: `5901`
- XFCE session
- OpenSSH server
- TigerVNC server

See `scripts/prepare-gentoo-guest.sh` for the guest-side setup.

## Keywords

Gentoo VM installer, easy Gentoo installer, one-click Gentoo VM, Hyper-V Gentoo, Windows Gentoo VM, beginner Gentoo Linux, Gentoo XFCE desktop, TigerVNC Gentoo launcher, install Gentoo in virtual machine.

## Status

Early but usable. Windows + Hyper-V is the first supported target.

