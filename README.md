# ez gentoo

Gentoo for larpers.

do u want to larp gentoo without spending days compiling, partitioning, reading wiki tabs, and wondering why the network hates you?

meet **ez gentoo**. made for larpers by larpers.

this boots a ready-to-play Gentoo desktop in a Hyper-V VM on Windows. configure the VM, press the button, leave it alone for a bit, then come back and pretend you are built different.

open a terminal. run `neofetch`. flex to your friends. mess with Portage. compile something if you feel brave. break it, fix it, learn Linux without nuking your real laptop.

## what it does

- downloads or imports a Gentoo VM disk
- creates the Hyper-V VM
- lets you choose install folder, VM name, RAM, CPU cores, and disk size
- disables Secure Boot for the VM so Gentoo actually boots
- starts the VM
- finds the random Hyper-V IP automatically
- waits until VNC is ready
- opens the Gentoo desktop fullscreen with TigerVNC

basically: Gentoo VM installer + launcher, but less ritual and more larp.

## download

grab `ez-gentoo-windows-x64.zip` from Releases.

run:

```text
EzGentooInstaller.exe
```

after setup, use:

```text
EzGentooLauncher.exe
```

## what u need

- Windows 10/11 Pro, Enterprise, or Education
- Hyper-V enabled
- virtualization enabled in BIOS/UEFI
- internet for the first install

if TigerVNC is missing, ez gentoo tries to install it with `winget`.

## important

the app is real, but the public one-click experience needs one more file in Releases:

```text
ez-gentoo-base.vhdx
```

that is the clean Gentoo desktop disk image. do not upload your personal VM disk unless it has been cleaned first. passwords, shell history, SSH keys, browser junk, all of that has to go.

## build

needs Visual Studio with C++ build tools:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\build-exe.ps1
```

output:

```text
dist/ez-gentoo-windows-x64/EzGentooInstaller.exe
dist/ez-gentoo-windows-x64/EzGentooLauncher.exe
dist/ez-gentoo-windows-x64.zip
```

## make a clean image

after preparing a clean VM:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\export-current-vm.ps1 -VmName GentooReady
```

upload the exported `ez-gentoo-base.vhdx` to a GitHub Release.

## search words, but honest

easy Gentoo VM, one click Gentoo installer, Gentoo Hyper-V VM, Gentoo VM for Windows, beginner Gentoo Linux, Gentoo XFCE desktop, install Gentoo in a virtual machine, TigerVNC Gentoo launcher, Linux larp setup.
