# omarchy-on-cachyos

- UPDATE 19-Jun-2026: Added system detection, optional autologin, email validation, guard bypass for ext4 and existing desktop environments. KDE/GNOME coexistence now supported.
- UPDATE 20-May-2026: The install script now includes interactive version selection for choosing between Stable releases and Bleeding Edge.
- UPDATE 1-October-2025: The install script has been updated to support Omarchy 3.0+ out of the box.

## 1. Introduction

This project provides an installation script for implementing DHH's Omarchy configuration on top of CachyOS. Omarchy is an 'opinionated' desktop setup, based on Hyprland that emphasizes simplicity and productivity, while CachyOS offers a performance-optimized Arch Linux distribution.

## 2. What This Script Does and Does Not Do

This installation script does the following three things:

  1) Prompts for and fetches your preferred version of Omarchy (Stable tags or Bleeding Edge)
  2) Makes adjustments to the Omarchy install scripts to support installation on CachyOS
  3) Launches the installation of Omarchy on an already setup CachyOS system
  4) Installs and configures NVIDIA 580xx proprietary drivers

This script does not:

 1) Install CachyOS or any other Linux operating system
 2) Partition, format, or encrypt hard disks
 3) Install or configure a boot loader
 5) Install or configure a login display manager

All of the above need to be done when you install CachyOS. 

## 3. Important Notes

This script (and README.md) is intended primarily for the experienced Arch Linux user. The author of this README.md assumes the reader is comfortable using a shell/command line and is familiar with Arch specific terms such as AUR.

The philosophy behind this script is to produce a strong and stable blend of CachyOS and Omarchy that changes as little as possible between the two. This script does not add software or make configuration changes outside of what CachyOS or Omarchy provide as default, except when such software or configurations provided by CachyOS and Omarchy are in conflict. In these cases, the script will choose the following:

1. AUR helper: CachyOS uses Paru by default while Omarchy uses Yay. This script opts for Yay and will install it if not already installed.

2. Shell: CachyOS uses the Fish shell by default while Omarchy uses Bash. This script will keep Fish as the default interactive shell.

3. TLDR implementation: CachyOS installs Tealdeer by default, which is a TLDR implementation written in Rust. This script will preserve use of Tealdeer.

4. Mise: Omarchy will setup Mise to run automatically via mise-activate. This script will supply the right mise-activate command for the fish shell.

5. Login System: As a distribution, Omarchy skips installation of a login display manager. Instead, Hyprland autostarts and password protection is provided upon boot by the LUKS full disk encryption service. This script, however, assumes a display manager is installed. (Note: this script does not install a display manager, but also does not configure Hyprland to start automatically if a display manager is not installed.)

6. Full Disk Encryption: As a distribution, Omarchy automatically turns on full disk encryption via LUKS. This script, however, leaves this decision up to the user. CachyOS can be installed with or without full disk encryption, and this script will install Omarchy on either setup.

7. NVIDIA Drivers: *By default, CachyOS and Omarchy may attempt to use the latest NVIDIA drivers with open kernel modules. This script explicitly downgrades/pins the driver to the* *580xx proprietary series* *using CachyOS's* `chwd` *tool. This is a deliberate choice to fix widespread issues with hardware acceleration, electron apps, and browser flickering.*

## 4. Pre-Requisites

IMPORTANT: This script does not install CachyOS. You must do that separately (and first.) This script is intended to be run on a fresh installation of CachyOS with the following configuration choices made: (Note, for information on installing CachyOS, please refer to https://www.cachyos.org.) 

1. File System: BTRFS is **not required** when using this script. The snapshot/rollback feature (`limine-snapper`) that Omarchy uses btrfs for is automatically disabled. **ext4, btrfs, and other filesystems are all supported.** The script will detect your filesystem at runtime and inform you of what is being skipped and why.

2. Shell: You must choose Fish as the default shell for this installation script to work properly. (This is the default CachyOS shell choice.)

3. Desktop Environment to Install: You can install a minimal system with no desktop environment, the CachyOS Hyprland desktop, KDE Plasma, or GNOME. **KDE and GNOME are now supported** — Omarchy will install alongside your existing desktop and appear as a selectable session at login. You do not need to uninstall your current desktop environment.

4. Graphics Drivers for NVIDIA users: 

5. This script now automatically handles NVIDIA driver installation by enforcing the proprietary 580xx drivers (via CachyOS `chwd`). This is necessary to avoid known regressions with hardware video decoding and browser flickering present in the newer open-kernel module drivers.

   **Important:** 

   To enable hardware video decode via NVDEC in chromium, you must:
   
   1. Add the following to `~/.config/chromium-flags.conf`:       ```       --enable-features=VaapiOnNvidiaGPUs       ```
   2. Install the [enhanced-h264ify extension](https://chromewebstore.google.com/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk) and disable **VP8** and **AV1** codecs.
   
   
   
   To fully enable hardware acceleration in Firefox, you must 
   
   1. Install the [enhanced-h264ify add-on](https://addons.mozilla.org/en-US/firefox/addon/enhanced-h264ify/) and disable **VP8** and **AV1** codecs and manually add the following overrides to your `user.js`:
   
   ```js
   // FORCE NVIDIA HARDWARE ACCELERATION
   user_pref("media.hardware-video-decoding.force-enabled", true);
   user_pref("media.hardware-video-encoding.force-enabled", true);
   user_pref("layers.acceleration.force-enabled", true);
   user_pref("webgl.force-enabled", true);
   user_pref("media.ffmpeg.vaapi.enabled", true);
   user_pref("media.rdd-ffmpeg.enabled", true);
   user_pref("media.av1.enabled", true);
   user_pref("widget.dmabuf.force-enabled", true);
   user_pref("gfx.x11-egl.force-enabled", true);
   ```

Other configuration changes are up to you. Note, however, that this script has not been extensively tested on various CachyOS installations other than the author's own machine.

## 5. Installation Instructions

```bash
# Clone the repository
git clone https://github.com/mroboff/omarchy-on-cachyos.git

# Navigate to the project directory
cd omarchy-on-cachyos/bin

# Make the script executable
chmod +x install-omarchy-on-cachyos.sh

# Run the installation script
./install-omarchy-on-cachyos.sh
```

**Note:** Please review the script contents before running to understand what changes will be made to your system.

## 6. Statement of Lack of Warranty

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Use this script at your own risk. Always backup your system and important data before running installation scripts.

## 7. CachyOS Compatibility Notes

The following changes are made automatically by this script to resolve conflicts between CachyOS and Omarchy's default assumptions. The script will print a summary of what was detected and skipped on your specific system before the installation begins.

| Issue | What the script does | Why |
|---|---|---|
| **Btrfs required** | Bypasses the guard; disables `limine-snapper` | CachyOS may use ext4 or other filesystems. Snapshot support is not required to use Omarchy. |
| **KDE/GNOME detected** | Bypasses the guard; installs Omarchy as an additional session | Omarchy coexists with your existing desktop — you pick your session at login. |
| **Autologin** | Asks you at install time: opt-in or opt-out | If you have KDE or another desktop, you likely want to choose your session at login rather than be auto-logged into Omarchy. |
| **SDDM config conflict** | Removes `/etc/sddm.conf` if present | CachyOS's SDDM config conflicts with Omarchy's UWSM session autologin setup. |
| **`tldr` conflict** | Removes `tldr` from Omarchy's package list | CachyOS ships Tealdeer (`tldr`), a Rust-based TLDR implementation. Installing both causes a conflict. |
| **`wpa_supplicant` conflict** | Disables `wpa_supplicant`; sets NetworkManager to use `iwd` | CachyOS enables `wpa_supplicant` by default, which conflicts with Omarchy's `iwd`, causing WiFi to appear connected but have no IP. |
| **`walker` version conflict** | Pins `walker` to the Omarchy repo via `IgnorePkg` | CachyOS ships a newer version of `walker` that is incompatible with Omarchy's `elephant` launcher. |
| **pacman.conf changes** | Skips Omarchy's `pacman.sh` preflight and post-install | Omarchy's `pacman.sh` overwrites CachyOS-specific pacman settings. |
| **Plymouth/bootloader** | Skips `plymouth.sh`, `limine-snapper.sh`, `alt-bootloaders.sh` | CachyOS manages its own bootloader. These scripts assume a fresh Arch install and would conflict with CachyOS's boot configuration. |
| **NVIDIA drivers** | Only installs if no driver is already present | CachyOS may already have the correct NVIDIA driver installed. The script checks before acting. |

### What `plymouth.sh` does (and when to run it manually)

`plymouth.sh` sets the Omarchy boot splash theme. It is **skipped automatically** during install because:
- If you have **KDE or GNOME**, your display manager already handles login — no action needed.
- If you have **multi-boot** (e.g. a Windows partition), your bootloader and boot menu are unaffected. Plymouth only changes the splash animation on the Linux side.

If you installed CachyOS **without any desktop environment** and want the Omarchy splash, run it manually after the install:
```bash
~/.local/share/omarchy/install/login/plymouth.sh
```

### Stable vs. Bleeding Edge

The install script will ask you which version of Omarchy to install. For CachyOS users, **Stable (latest tag) is recommended**. The compatibility patches in this script are written against the current stable release. Bleeding edge may change install paths or script logic in ways that break the patches mid-install.

## 7. How to Contribute

We welcome contributions to improve this project! Here's how you can help:

1. **Fork the Repository**: Click the "Fork" button on GitHub to create your own copy
2. **Create a Feature Branch**: `git checkout -b feature/your-feature-name`
3. **Make Your Changes**: Implement your improvements or fixes
4. **Commit Your Changes**: `git commit -m "Add descriptive commit message"`
5. **Push to Your Fork**: `git push origin feature/your-feature-name`
6. **Open a Pull Request**: Submit a PR with a clear description of your changes

### Contribution Guidelines
- Test your changes thoroughly on CachyOS before submitting
- Follow existing code style and conventions
- Update documentation if adding new features
- Report bugs using GitHub Issues 
