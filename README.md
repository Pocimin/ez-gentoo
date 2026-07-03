# ez gentoo

Gentoo for larpers.

This is for the person who wants to click one button, boot a real Gentoo desktop in a VM, run `neofetch`, poke Portage with a stick, and feel like a Linux wizard for the evening.

No shame. That is a valid spiritual calling.

The normal Gentoo install is cool, but it is also a whole side quest. `ez gentoo` is the lazy path into the playground.

## Download

Grab `ez-gentoo-windows-x64.zip` from Releases, unzip it, and run:

```text
EzGentooInstaller.exe
```

After it is installed, use:

```text
EzGentooLauncher.exe
```

## What The App Does

The app is a native C++ Windows app with Dear ImGui for the UI.

It can:

- ask for admin on launch
- pick where the VM lives
- choose RAM, CPU cores, and disk size
- download or import a Gentoo VM image
- create the Hyper-V VM
- disable Secure Boot for that VM
- start Gentoo
- find the VM's changing Hyper-V IP automatically
- wait for VNC instead of opening too early and exploding
- launch the Gentoo desktop fullscreen

Basically: less ritual, more desktop.

## What You Need

- Windows 10/11 Pro, Enterprise, or Education
- Hyper-V enabled
- virtualization enabled in BIOS/UEFI
- TigerVNC Viewer
- an internet connection for first install

If TigerVNC is missing, the app tries to install it with `winget`.

## The One Big Missing Piece

The app is ready. The public base image still has to be uploaded:

```text
ez-gentoo-base.vhdx
```

That file is the prepared Gentoo desktop disk. It does **not** belong in git, and we should not upload a personal VM disk with passwords, shell history, SSH junk, or whatever else is lying around in it.

Make a clean image, upload it to Releases, and then the installer becomes the real one-click thing.

## Build

Needs Visual Studio with C++ build tools:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\build-exe.ps1
```

Output:

```text
dist/ez-gentoo-windows-x64/EzGentooInstaller.exe
dist/ez-gentoo-windows-x64/EzGentooLauncher.exe
dist/ez-gentoo-windows-x64.zip
```

The build script fetches Dear ImGui into `external/imgui`.

## Make The Gentoo Image

After preparing a clean VM:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\export-current-vm.ps1 -VmName GentooReady
```

Upload the exported `ez-gentoo-base.vhdx` to a GitHub Release.

## Search Bait, But Honest

Gentoo VM installer, easy Gentoo installer, one-click Gentoo VM, Hyper-V Gentoo, beginner Gentoo Linux, Gentoo XFCE desktop, TigerVNC Gentoo launcher, install Gentoo in a virtual machine, Linux larp setup.

