# changelog

## v0.1.0

first public larp drop.

we got gentoo booting in a Hyper-V VM from a real Windows app. no wiki marathon, no partition ritual, no "just compile the universe real quick bro" moment.

- added the actual `EzGentooInstaller.exe` and `EzGentooLauncher.exe`
- ships with the Fang-ish dark ImGui UI instead of the cursed Windows Forms prototype
- downloads the public base image from the ez gentoo VPS
- shows real download progress now, with percent and GB downloaded
- creates the Hyper-V VM, turns off Secure Boot, sets RAM/CPU/disk, starts it, finds the IP, then opens TigerVNC
- lets u reuse an existing Gentoo VM if u already made one while larping too hard
- fixed the random PowerShell XML nonsense that could leak into the VM name field
- made the title bar dark so the window no longer wears a white hat for no reason
- included Poppins so the app stops looking like it was born in Control Panel

known vibe:

- first install still downloads a huge image, because Gentoo with a desktop is not exactly tiny
- Hyper-V is required, so Windows Home users are still in "sorry bestie" territory
- this is for learning, flexing, and breaking a toy Linux box. do not treat it like prod.
