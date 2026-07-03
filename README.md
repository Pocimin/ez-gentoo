# ez gentoo

Gentoo in a VM, without pretending your first Linux night needs to be a sacred trial.

`ez gentoo` is a Windows app for people who want to open a real Gentoo desktop, run Portage, post the `neofetch`, break a few things, and learn by messing around. The manual install can come later. This is the front door.

## What You Download

Grab `ez-gentoo-windows-x64.zip` from Releases, unzip it, and run:

```text
EzGentooInstaller.exe
```

There is also:

```text
EzGentooLauncher.exe
```

Use the installer for first setup. Use the launcher after that.

## What The App Does

- asks for admin because Hyper-V requires it
- downloads or imports a Gentoo VM image
- lets you choose VM name, install folder, RAM, CPU count, and disk size
- creates a Hyper-V VM
- disables Secure Boot for the VM
- starts Gentoo
- finds the VM's changing Hyper-V IP automatically
- waits until the desktop is actually reachable
- opens TigerVNC fullscreen

No guessing IPs. No typing random commands into PowerShell because a tutorial said so.

## Requirements

- Windows 10/11 Pro, Enterprise, or Education
- Hyper-V enabled
- virtualization enabled in BIOS/UEFI
- internet connection for first install
- TigerVNC Viewer

The app tries to install TigerVNC with `winget` if it is missing.

## The Missing Artifact

The code is ready for a one-click flow, but a public install also needs this release asset:

```text
ez-gentoo-base.vhdx
```

That file is the prepared Gentoo desktop image. It is not committed to git, because VM images are huge and usually contain local secrets if you are careless.

To ship a public build, sanitize a base VM, export it, then upload `ez-gentoo-base.vhdx` to a GitHub Release.

## Build The App

Requires .NET 8 SDK:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\build-exe.ps1
```

Output:

```text
dist/ez-gentoo-windows-x64/EzGentooInstaller.exe
dist/ez-gentoo-windows-x64/EzGentooLauncher.exe
dist/ez-gentoo-windows-x64.zip
```

## Make A Release Image

After preparing a clean VM:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\export-current-vm.ps1 -VmName GentooReady
```

Upload the exported `ez-gentoo-base.vhdx` to Releases.

## For The Search Box

Gentoo VM installer, easy Gentoo installer, one-click Gentoo VM, Hyper-V Gentoo, beginner Gentoo Linux, Gentoo XFCE desktop, TigerVNC Gentoo launcher, install Gentoo in a virtual machine.

