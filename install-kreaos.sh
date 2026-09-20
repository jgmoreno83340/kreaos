#!/usr/bin/env bash
#
# KreaOS installer - an Arch Linux base for creative work.
#
#   Desktop : Window Maker (X11) + LightDM + Kando pie menu
#   Creative: Inkscape, Scribus, Blender, Darktable, MyPaint, AzPainter, GIMP,
#             MakeHuman, Kdenlive, OpenShot, Synfig Studio, SculptGL
#   Extras  : Firefox, LibreOffice, VLC, Shotwell, Evince, SimpleScreenRecorder,
#             network / disk tools, Samba sharing, Wine
#
# Adapted from the auto-install script by @sandipsky8756.
#
# Run from the Arch Linux live ISO, as root, with a working internet connection.
# WARNING: this formats the ROOT partition (and, optionally, the EFI partition).

set -euo pipefail

### ------------------------------------------------------------------
### PRE-FLIGHT CHECKS
### ------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root." >&2
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "This installer needs UEFI. Boot the live ISO in UEFI mode." >&2
    exit 1
fi

if ! ping -c1 -W3 archlinux.org &>/dev/null; then
    echo "No internet connection. Connect first (e.g. with iwctl) and retry." >&2
    exit 1
fi

timedatectl set-ntp true || true

### ------------------------------------------------------------------
### QUESTIONS
### ------------------------------------------------------------------
ask() {   # ask VAR "Prompt" [default]
    local __var=$1 __prompt=$2 __default=${3:-} __reply
    if [[ -n $__default ]]; then
        read -rp "$__prompt [$__default]: " __reply
        __reply=${__reply:-$__default}
    else
        read -rp "$__prompt: " __reply
    fi
    printf -v "$__var" '%s' "$__reply"
}

echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
echo

ask EFI  "EFI partition (e.g. /dev/nvme0n1p1)"
ask ROOT "ROOT partition (e.g. /dev/nvme0n1p2)"
ask NTFS_DRIVE "NTFS data drive partition (optional, e.g. /dev/nvme1n1p1, blank to skip)" ""
ask FORMAT_EFI "Format the EFI partition? Say 'n' if it is shared with Windows/another OS (y/n)" "y"

[[ -b $EFI  ]] || { echo "$EFI is not a block device." >&2; exit 1; }
[[ -b $ROOT ]] || { echo "$ROOT is not a block device." >&2; exit 1; }
if [[ -n $NTFS_DRIVE && ! -b $NTFS_DRIVE ]]; then
    echo "$NTFS_DRIVE is not a block device." >&2
    exit 1
fi

ask KREA_USER "Username"
if [[ ! $KREA_USER =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Usernames must be lowercase letters, digits, '_' or '-', starting with a letter." >&2
    exit 1
fi
ask FULLNAME "Full name" "$KREA_USER"

while true; do
    read -rsp "Password: " PASSWORD; echo
    read -rsp "Confirm password: " PASSWORD2; echo
    [[ -n $PASSWORD && $PASSWORD == "$PASSWORD2" ]] && break
    echo "Passwords were empty or did not match, try again."
done

ask HOSTNAME_NEW "Hostname" "kreaos"
ask TIMEZONE "Timezone (Region/City)" "Europe/London"
[[ -f /usr/share/zoneinfo/$TIMEZONE ]] || { echo "Unknown timezone: $TIMEZONE" >&2; exit 1; }
ask KEYMAP  "Console keymap (e.g. uk, us, fr)" "uk"
ask XLAYOUT "X11 keyboard layout (e.g. gb, us, fr)" "gb"

### ------------------------------------------------------------------
### HARDWARE DETECTION
### ------------------------------------------------------------------
GPU_INFO=$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)
HAS_INTEL=0; HAS_AMD=0; HAS_NVIDIA=0
grep -qi 'intel'        <<<"$GPU_INFO" && HAS_INTEL=1  || true
grep -qiE 'amd|ati|radeon' <<<"$GPU_INFO" && HAS_AMD=1 || true
grep -qi 'nvidia'       <<<"$GPU_INFO" && HAS_NVIDIA=1 || true

UCODE=""
if   grep -q GenuineIntel /proc/cpuinfo; then UCODE="intel-ucode"
elif grep -q AuthenticAMD /proc/cpuinfo; then UCODE="amd-ucode"
fi

VIRT=$(systemd-detect-virt || true)

INSTALL_CUDA=0
if (( HAS_NVIDIA )); then
    echo
    echo "NVIDIA GPU detected. The open kernel modules (nvidia-open) support Turing"
    echo "and newer (GTX 16xx / RTX). Older cards need a legacy driver from the AUR."
    ask CUDA_ANSWER "Install CUDA for Blender GPU rendering? It is a large download (y/n)" "n"
    [[ $CUDA_ANSWER =~ ^[Yy] ]] && INSTALL_CUDA=1 || true
fi

echo
echo "About to ERASE and format: $ROOT (root)"
[[ $FORMAT_EFI =~ ^[Yy] ]] && echo "About to ERASE and format: $EFI (EFI)"
echo "Detected: CPU microcode='${UCODE:-none}', GPU intel=$HAS_INTEL amd=$HAS_AMD nvidia=$HAS_NVIDIA, virt=${VIRT:-none}"
read -rp "Type YES (capitals) to continue: " CONFIRM
[[ $CONFIRM == "YES" ]] || { echo "Aborted."; exit 1; }

### ------------------------------------------------------------------
### FILESYSTEMS
### ------------------------------------------------------------------
umount -R /mnt 2>/dev/null || true

if [[ $FORMAT_EFI =~ ^[Yy] ]]; then
    mkfs.fat -F32 "$EFI"
fi
mkfs.ext4 -F "$ROOT"

mount -o noatime "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

### ------------------------------------------------------------------
### BASE SYSTEM
### ------------------------------------------------------------------
pacman -Sy --noconfirm archlinux-keyring

BASE_PKGS=(
    base base-devel
    linux linux-firmware sof-firmware
    networkmanager
    vim nano git git-lfs curl wget
    man-db man-pages bash-completion
    pciutils usbutils efibootmgr
    zram-generator
    power-profiles-daemon
    bluez bluez-utils
    ntfs-3g
    pipewire wireplumber pipewire-alsa pipewire-pulse
)
[[ -n $UCODE ]] && BASE_PKGS+=("$UCODE")

pacstrap /mnt --noconfirm --needed "${BASE_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
NTFS_UUID=""
if [[ -n $NTFS_DRIVE ]]; then
    NTFS_UUID=$(blkid -s UUID -o value "$NTFS_DRIVE")
fi

### ------------------------------------------------------------------
### USER + PASSWORDS (done here so nothing secret is written to a script)
### ------------------------------------------------------------------
arch-chroot /mnt useradd -m -s /bin/bash -c "$FULLNAME" "$KREA_USER"
for grp in wheel video audio storage input render lp scanner optical; do
    if arch-chroot /mnt getent group "$grp" &>/dev/null; then
        arch-chroot /mnt usermod -aG "$grp" "$KREA_USER"
    fi
done
printf '%s:%s\n' "$KREA_USER" "$PASSWORD" | arch-chroot /mnt chpasswd
arch-chroot /mnt passwd -l root >/dev/null   # root is locked; use sudo

### ------------------------------------------------------------------
### VALUES PASSED TO THE CHROOT SCRIPT (no passwords)
### ------------------------------------------------------------------
CONF=/mnt/root/.kreaos-install.conf
{
    printf 'KREA_USER=%q\n'    "$KREA_USER"
    printf 'FULLNAME=%q\n'     "$FULLNAME"
    printf 'HOSTNAME_NEW=%q\n' "$HOSTNAME_NEW"
    printf 'TIMEZONE=%q\n'     "$TIMEZONE"
    printf 'KEYMAP=%q\n'       "$KEYMAP"
    printf 'XLAYOUT=%q\n'      "$XLAYOUT"
    printf 'ROOT_UUID=%q\n'    "$ROOT_UUID"
    printf 'NTFS_UUID=%q\n'    "$NTFS_UUID"
    printf 'VIRT=%q\n'         "${VIRT:-none}"
    printf 'UCODE=%q\n'        "$UCODE"
    printf 'HAS_INTEL=%q\n'    "$HAS_INTEL"
    printf 'HAS_AMD=%q\n'      "$HAS_AMD"
    printf 'HAS_NVIDIA=%q\n'   "$HAS_NVIDIA"
    printf 'INSTALL_CUDA=%q\n' "$INSTALL_CUDA"
} > "$CONF"
chmod 600 "$CONF"

### ------------------------------------------------------------------
### CHROOT SCRIPT
### ------------------------------------------------------------------
cat <<'KREAOS_CHROOT' > /mnt/root/kreaos-chroot.sh
#!/usr/bin/env bash
set -euo pipefail
cd /tmp

# shellcheck disable=SC1091
source /root/.kreaos-install.conf

### --- PACKAGE HELPERS ---
# Arch moves packages between the official repos and the AUR over time.
# pkg_install installs what the repos have, defers the rest to yay, and never
# aborts the whole install because one package is missing or broken.
# Anything that fails ends up in ~/failed-packages.txt.
MISSING_PKGS=()
FAILED_PKGS=()

pkg_install() {
    local available=() pkg
    for pkg in "$@"; do
        if pacman -Si "$pkg" &>/dev/null; then
            available+=("$pkg")
        else
            echo "WARNING: $pkg not in official repos (moved to AUR?), deferring to yay"
            MISSING_PKGS+=("$pkg")
        fi
    done
    if (( ${#available[@]} )); then
        pacman -S --noconfirm --needed "${available[@]}" || {
            echo "WARNING: batch install failed, retrying one at a time"
            for pkg in "${available[@]}"; do
                pacman -S --noconfirm --needed "$pkg" || {
                    echo "WARNING: pacman failed to install $pkg, continuing"
                    FAILED_PKGS+=("$pkg")
                }
            done
        }
    fi
}

aur_install() {
    local pkg
    for pkg in "$@"; do
        sudo -u "$KREA_USER" -H yay -S --noconfirm --needed "$pkg" || {
            echo "WARNING: AUR build failed for $pkg, continuing"
            FAILED_PKGS+=("$pkg")
        }
    done
}

### --- SUDO ---
# Normal sudo (with password) for the wheel group. AUR builds need passwordless
# sudo while this script runs, so a temporary rule is added and always removed.
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
echo "$KREA_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-kreaos-install
chmod 440 /etc/sudoers.d/99-kreaos-install
trap 'rm -f /etc/sudoers.d/99-kreaos-install /root/.kreaos-install.conf' EXIT

### --- LOCALE / TIME / KEYBOARD ---
sed -i 's/^#en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/; s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP"   > /etc/vconsole.conf

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true

mkdir -p /etc/X11/xorg.conf.d
cat <<XKB > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$XLAYOUT"
EndSection
XKB

### --- HOSTNAME ---
echo "$HOSTNAME_NEW" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
HOSTS

### --- PACMAN / MAKEPKG TWEAKS ---
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i "s/^#MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf
pacman -Syy --noconfirm

### --- BOOTLOADER ---
# Installed early so the system is always bootable, even if a later
# (network/AUR) step fails.
bootctl install --esp-path=/boot

cat <<LOADER > /boot/loader/loader.conf
default kreaos.conf
timeout 3
console-mode keep
editor no
LOADER

CMDLINE="root=UUID=$ROOT_UUID rw quiet"
if (( HAS_NVIDIA )); then
    CMDLINE+=" nvidia-drm.modeset=1"
fi
{
    echo "title   KreaOS"
    echo "linux   /vmlinuz-linux"
    if [[ -n $UCODE ]]; then
        echo "initrd  /$UCODE.img"
    fi
    echo "initrd  /initramfs-linux.img"
    echo "options $CMDLINE"
} > /boot/loader/entries/kreaos.conf
systemctl enable systemd-boot-update.service

### --- ZRAM ---
cat <<'ZRAM' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

### --- GRAPHICS DRIVERS (detected) ---
GPU_PKGS=(mesa vulkan-icd-loader)
(( HAS_INTEL ))  && GPU_PKGS+=(vulkan-intel intel-media-driver) || true
(( HAS_AMD ))    && GPU_PKGS+=(vulkan-radeon) || true
if (( HAS_NVIDIA )); then
    GPU_PKGS+=(nvidia-open nvidia-utils lib32-nvidia-utils nvidia-settings opencl-nvidia libva-nvidia-driver)
    # Laptops with Intel/AMD + NVIDIA: run apps on the NVIDIA card with `prime-run <app>`
    if (( HAS_INTEL || HAS_AMD )); then
        GPU_PKGS+=(nvidia-prime)
    fi
    if (( INSTALL_CUDA )); then
        GPU_PKGS+=(cuda)
    fi
fi
pkg_install "${GPU_PKGS[@]}"

### --- VIRTUAL MACHINE GUEST TOOLS ---
case "$VIRT" in
    oracle|virtualbox)
        pkg_install virtualbox-guest-utils
        usermod -aG vboxsf "$KREA_USER" || true
        systemctl enable vboxservice.service || true
        ;;
    kvm|qemu)
        pkg_install qemu-guest-agent spice-vdagent
        systemctl enable qemu-guest-agent.service || true
        ;;
    vmware)
        pkg_install open-vm-tools
        systemctl enable vmtoolsd.service || true
        ;;
esac

### --- XORG + WINDOW MAKER DESKTOP ---
pkg_install \
    xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xset xorg-xrdb \
    xf86-input-libinput xf86-input-wacom libwacom \
    xdg-utils xdg-user-dirs \
    windowmaker \
    picom dunst arandr \
    polkit-gnome \
    lightdm lightdm-gtk-greeter \
    lxappearance-gtk3 qt6ct \
    xterm xfce4-terminal mousepad \
    thunar thunar-volman thunar-shares-plugin tumbler ffmpegthumbnailer xarchiver \
    gvfs gvfs-mtp gvfs-smb \
    pavucontrol pipewire-jack \
    blueman

### --- NETWORK TOOLS ---
pkg_install \
    network-manager-applet networkmanager-openvpn \
    iw bind traceroute nmap

### --- DISK TOOLS ---
pkg_install \
    gparted gnome-disk-utility \
    parted gptfdisk \
    dosfstools e2fsprogs btrfs-progs xfsprogs exfatprogs mtools \
    smartmontools nvme-cli \
    udisks2 udiskie

### --- SAMBA (file sharing) ---
pkg_install samba smbclient cifs-utils avahi

groupadd -f sambashare
mkdir -p /var/lib/samba/usershares
chown root:sambashare /var/lib/samba/usershares
chmod 1770 /var/lib/samba/usershares
usermod -aG sambashare "$KREA_USER"

mkdir -p /etc/samba
cat <<'SMB' > /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   server string = KreaOS
   server role = standalone server
   map to guest = never
   log file = /var/log/samba/%m.log
   max log size = 50

   # Members of the "sambashare" group can share folders themselves
   # (Thunar: right-click a folder > Share Options). No guest access.
   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = no
   usershare owner only = yes
SMB

### --- WINE ---
# wine >= 10 is WoW64: 32-bit Windows apps run on 64-bit libraries, so the
# long lib32-* list from the original script is not needed.
pkg_install \
    wine-staging wine-mono wine-gecko winetricks \
    giflib gnutls libpulse alsa-plugins openal v4l-utils \
    gst-plugins-base-libs gst-plugins-good gst-libav

### --- FONTS ---
pkg_install \
    noto-fonts noto-fonts-emoji noto-fonts-extra noto-fonts-cjk \
    ttf-liberation ttf-dejavu ttf-fira-sans ttf-jetbrains-mono \
    otf-font-awesome

### --- CREATIVE APPLICATIONS ---
pkg_install \
    inkscape scribus ghostscript \
    blender \
    darktable \
    mypaint \
    gimp \
    kdenlive openshot synfigstudio \
    ffmpeg frei0r-plugins mediainfo

### --- PC, MEDIA AND UTILITIES ---
pkg_install \
    firefox firefox-i18n-en-gb \
    libreoffice-fresh libreoffice-fresh-en-gb hunspell-en_gb \
    vlc vlc-plugins-all \
    shotwell \
    evince \
    simplescreenrecorder

### --- AUR HELPER (yay) ---
# yay-bin avoids compiling Go during the install.
sudo -u "$KREA_USER" -H git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
( cd /tmp/yay-bin && sudo -u "$KREA_USER" -H makepkg -sri --needed --noconfirm )
rm -rf /tmp/yay-bin

### --- AUR APPLICATIONS ---
# AzPainter and the Kando pie menu are AUR-only.
aur_install azpainter kando-bin

### --- MAKEHUMAN ---
# The AUR package downloads ~260 MB of assets through git-lfs and has been
# reported as breaking. If it fails, fall back to the upstream README method
# (source checkout in /opt/makehuman).
install_makehuman_from_source() {
    pacman -S --noconfirm --needed python python-numpy python-pyqt5 python-pyopengl git git-lfs || return 1
    rm -rf /opt/makehuman
    git lfs install --skip-repo || true
    git clone --depth 1 https://github.com/makehumancommunity/makehuman.git /opt/makehuman || return 1
    ( cd /opt/makehuman/makehuman && python download_assets_git.py ) || return 1
    ( cd /opt/makehuman/makehuman \
        && python compile_targets.py \
        && python compile_proxies.py \
        && python compile_models.py ) || echo "WARNING: optional MakeHuman compile steps failed"

    cat <<'MHLAUNCH' > /usr/local/bin/makehuman
#!/usr/bin/env bash
cd /opt/makehuman/makehuman && exec python3 makehuman.py "$@"
MHLAUNCH
    chmod 755 /usr/local/bin/makehuman

    cat <<'MHDESKTOP' > /usr/share/applications/makehuman.desktop
[Desktop Entry]
Type=Application
Name=MakeHuman
Comment=Parametric 3D human modelling
Exec=makehuman
Icon=applications-graphics
Terminal=false
Categories=Graphics;3DGraphics;
MHDESKTOP
}

if ! sudo -u "$KREA_USER" -H yay -S --noconfirm --needed makehuman; then
    echo "WARNING: AUR makehuman failed, trying the source install from the upstream README"
    if ! install_makehuman_from_source; then
        FAILED_PKGS+=(makehuman)
    fi
fi

### --- SCULPTGL ---
# SculptGL is a WebGL app (no distro package) and is archived upstream.
# Try to build an offline copy; otherwise fall back to the online version.
install_sculptgl() {
    local dest=/usr/share/kreaos/sculptgl build had_node=0
    pacman -Q nodejs &>/dev/null && had_node=1
    build=$(mktemp -d)

    if pacman -S --noconfirm --needed nodejs npm git \
        && git clone --depth 1 https://github.com/stephomi/sculptgl.git "$build/sculptgl" \
        && ( cd "$build/sculptgl" \
             && npm install --ignore-scripts --no-audit --no-fund \
             && npm run release ) \
        && [[ -f $build/sculptgl/app/index.html ]]; then
        mkdir -p "$dest"
        cp -r "$build/sculptgl/app/." "$dest/"
        cp "$build"/sculptgl/LICENSE* "$dest/" 2>/dev/null || true
        echo "SculptGL built for offline use."
    else
        echo "WARNING: offline SculptGL build failed, the launcher will use the online version."
    fi

    rm -rf "$build"
    if (( ! had_node )); then
        pacman -Rns --noconfirm nodejs npm || true
    fi
}
install_sculptgl || true

cat <<'SCULPTLAUNCH' > /usr/local/bin/kreaos-sculptgl
#!/usr/bin/env bash
# Opens SculptGL in Firefox: local copy if present, online version otherwise.
DIR=/usr/share/kreaos/sculptgl
PORT=8765
if [[ -f $DIR/index.html ]]; then
    if ! ss -ltn 2>/dev/null | grep -q ":$PORT "; then
        python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR" >/dev/null 2>&1 &
        sleep 1
    fi
    URL="http://127.0.0.1:$PORT/index.html"
else
    URL="https://stephomi.github.io/sculptgl/"
fi
exec firefox --new-window "$URL"
SCULPTLAUNCH
chmod 755 /usr/local/bin/kreaos-sculptgl

cat <<'SCULPTDESKTOP' > /usr/share/applications/kreaos-sculptgl.desktop
[Desktop Entry]
Type=Application
Name=SculptGL
Comment=Digital sculpting in the browser
Exec=kreaos-sculptgl
Icon=applications-graphics
Terminal=false
Categories=Graphics;3DGraphics;
SCULPTDESKTOP

### --- REPO-DROPPED PACKAGES (AUR fallback) ---
if (( ${#MISSING_PKGS[@]} )); then
    echo "Installing packages that moved to AUR: ${MISSING_PKGS[*]}"
    aur_install "${MISSING_PKGS[@]}"
fi

### --- NTFS DATA DRIVE ---
if [[ -n $NTFS_UUID ]]; then
    KREA_UID=$(id -u "$KREA_USER")
    KREA_GID=$(id -g "$KREA_USER")
    mkdir -p /mnt/data
    echo "UUID=$NTFS_UUID /mnt/data ntfs-3g uid=$KREA_UID,gid=$KREA_GID,umask=022,windows_names,nosuid,nodev,nofail,x-gvfs-show 0 0" >> /etc/fstab
else
    echo "No separate NTFS drive specified, skipping..."
fi

### --- LOGIN SCREEN + SESSION ---
cat <<'XSESSION' > /usr/share/xsessions/kreaos.desktop
[Desktop Entry]
Name=KreaOS (Window Maker)
Comment=Window Maker with the Kando pie menu
Exec=wmaker
Type=Application
DesktopNames=WindowMaker
XSESSION

mkdir -p /etc/lightdm/lightdm.conf.d
cat <<'LIGHTDM' > /etc/lightdm/lightdm.conf.d/50-kreaos.conf
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=kreaos
LIGHTDM

### --- WINDOW MAKER: AUTOSTART + STARTX FALLBACK ---
WM_DIR="/home/$KREA_USER/GNUstep/Library/WindowMaker"
mkdir -p "$WM_DIR"
cat <<'AUTOSTART' > "$WM_DIR/autostart"
#!/bin/sh
# Runs once when Window Maker starts.

# Password prompts for GParted, GNOME Disks, etc.
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &

# Compositor: Kando needs one for its transparency.
picom -b

# Notifications and automatic mounting of USB drives.
dunst &
udiskie &

# Pie menu (Ctrl+Space by default).
kando &
AUTOSTART
chmod 755 "$WM_DIR/autostart"

echo 'exec dbus-run-session wmaker' > "/home/$KREA_USER/.xinitrc"
chown -R "$KREA_USER:$KREA_USER" "/home/$KREA_USER/GNUstep" "/home/$KREA_USER/.xinitrc"

sudo -u "$KREA_USER" -H xdg-user-dirs-update || true

### --- SERVICES ---
systemctl enable NetworkManager bluetooth power-profiles-daemon fstrim.timer
systemctl enable systemd-timesyncd lightdm avahi-daemon smb nmb
systemctl --global enable pipewire pipewire-pulse wireplumber
systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service

### --- REBUILD INITRAMFS (picks up keymap etc.) ---
mkinitcpio -P

### --- FAILED PACKAGE REPORT ---
if (( ${#FAILED_PKGS[@]} )); then
    printf '%s\n' "${FAILED_PKGS[@]}" > "/home/$KREA_USER/failed-packages.txt"
    chown "$KREA_USER:$KREA_USER" "/home/$KREA_USER/failed-packages.txt"
    echo "WARNING: these packages failed to install (saved to ~/failed-packages.txt):"
    printf '  %s\n' "${FAILED_PKGS[@]}"
    echo 'Retry after reboot with: yay -S --needed $(cat ~/failed-packages.txt)'
fi

echo "INSTALLATION COMPLETE"
KREAOS_CHROOT

chmod +x /mnt/root/kreaos-chroot.sh

# Run the chroot part, keeping a log on the new system.
arch-chroot /mnt /root/kreaos-chroot.sh 2>&1 | tee /mnt/var/log/kreaos-install.log
rm -f /mnt/root/kreaos-chroot.sh /mnt/root/.kreaos-install.conf

### ------------------------------------------------------------------
### SAMBA PASSWORD (same as the login password; change with `smbpasswd`)
### ------------------------------------------------------------------
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" \
    | arch-chroot /mnt smbpasswd -a -s "$KREA_USER" \
    || echo "NOTE: could not set a Samba password. Run 'sudo smbpasswd -a $KREA_USER' after booting."

sync
echo
echo "DONE. Run 'umount -R /mnt', then reboot."
echo "Install log: /var/log/kreaos-install.log (on the new system)"
