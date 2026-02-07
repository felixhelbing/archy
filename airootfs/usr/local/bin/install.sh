#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

cleanup() {
  set +e
  if mountpoint -q /mnt; then
    umount -R /mnt 2>/dev/null || true
  fi
  if [[ -e /dev/mapper/cryptroot ]]; then
    cryptsetup close cryptroot 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- preflight ---
for c in lsblk sgdisk partprobe mkfs.fat mkfs.ext4 cryptsetup pacstrap genfstab arch-chroot blkid awk sed dd mountpoint; do
  require "$c"
done

# --- disk selection (filter out USB + removable) ---
echo "== Disks (USB filtered out) =="

mapfile -t DISK_LINES < <(
  lsblk -dpno NAME,SIZE,MODEL,TYPE,TRAN,RM \
  | awk '$4=="disk" && $5!="usb" && $6==0 {print}'
)

((${#DISK_LINES[@]})) || die "No suitable non-USB disks found."

if (( ${#DISK_LINES[@]} == 1 )); then
  IDX=0
  name="$(echo "${DISK_LINES[0]}" | awk '{print $1}')"
  size="$(echo "${DISK_LINES[0]}" | awk '{print $2}')"
  model="$(echo "${DISK_LINES[0]}" | cut -d' ' -f3- | sed 's/  *disk .*//')"
  echo "One disk found: $name ($size, $model)"
else
  for i in "${!DISK_LINES[@]}"; do
    name="$(echo "${DISK_LINES[$i]}" | awk '{print $1}')"
    size="$(echo "${DISK_LINES[$i]}" | awk '{print $2}')"
    model="$(echo "${DISK_LINES[$i]}" | cut -d' ' -f3- | sed 's/  *disk .*//')"
    printf "[%d] %s  (%s, %s)\n" "$i" "$name" "$size" "$model"
  done

  read -rp "Select disk number to ERASE and install to: " IDX
  [[ "$IDX" =~ ^[0-9]+$ ]] || die "Not a number."
  (( IDX < ${#DISK_LINES[@]} )) || die "Out of range."
fi

DISK="$(echo "${DISK_LINES[$IDX]}" | awk '{print $1}')"

LUKS_PW="foo"
USERNAME="q"
USER_PW="foo"

# --- CPU microcode selection ---
UCPKG=""
if grep -qi 'GenuineIntel' /proc/cpuinfo; then
  UCPKG="intel-ucode"
elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  UCPKG="amd-ucode"
fi

# --- partition (UEFI) ---
echo "== Partitioning $DISK =="
echo "Wiping partition table..."
sgdisk --zap-all "$DISK"
echo "Creating EFI partition..."
sgdisk -n 1:0:+512MiB -t 1:EF00 -c 1:"EFI" "$DISK"
echo "Creating root partition..."
sgdisk -n 2:0:0        -t 2:8300 -c 2:"cryptroot" "$DISK"
partprobe "$DISK"

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
  EFI="${DISK}p1"
  ROOT="${DISK}p2"
else
  EFI="${DISK}1"
  ROOT="${DISK}2"
fi

for _ in {1..50}; do
  [[ -b "$EFI" && -b "$ROOT" ]] && break
  sleep 0.2
done
[[ -b "$EFI" && -b "$ROOT" ]] || die "Partitions not found."

echo "== Formatting =="
mkfs.fat -F32 "$EFI"

echo "== Encrypting root partition =="
printf "%s" "$LUKS_PW" | cryptsetup luksFormat --type luks2 "$ROOT" -
printf "%s" "$LUKS_PW" | cryptsetup open "$ROOT" cryptroot -

mkfs.ext4 -F /dev/mapper/cryptroot

echo "== Mounting =="
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- install base system ---
echo "== Installing packages =="
mapfile -t PACSTRAP_PKGS < <(grep -v '^#' /usr/share/installer/install-packages | grep .)

pacstrap -C /usr/share/installer/pacman-offline.conf -G /mnt "${PACSTRAP_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab


# --- seed /etc/skel in target system (must happen BEFORE useradd -m) ---
INSTALLER_SKEL_SRC="/usr/share/installer/skel"
INSTALLER_SKEL_DST="/mnt/etc/skel"

[[ -d "$INSTALLER_SKEL_SRC" ]] || die "Missing installer skel dir: $INSTALLER_SKEL_SRC"

mkdir -p "$INSTALLER_SKEL_DST"
cp -a "$INSTALLER_SKEL_SRC"/. "$INSTALLER_SKEL_DST"/
chmod +x "$INSTALLER_SKEL_DST"/.local/bin/install-brave
chmod +x "$INSTALLER_SKEL_DST"/.local/bin/install-librewolf

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"

echo "== Configuring system =="
arch-chroot /mnt /bin/bash -e <<'CHROOT'
set -euo pipefail
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us' > /etc/vconsole.conf
echo 'archpc' > /etc/hostname
systemctl enable NetworkManager
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
CHROOT

# --- system files (services, scripts) ---
cp -a /usr/share/installer/system/. /mnt/
chmod +x /mnt/usr/local/lib/early-boot.sh
arch-chroot /mnt systemctl enable early-boot.service

echo "== Installing bootloader =="
arch-chroot /mnt bootctl install

cat > /mnt/boot/loader/loader.conf <<'LDR'
default arch.conf
timeout 0
editor no
LDR

UC_LINE=""
[[ -f /mnt/boot/intel-ucode.img ]] && UC_LINE="initrd  /intel-ucode.img"
[[ -f /mnt/boot/amd-ucode.img   ]] && UC_LINE="initrd  /amd-ucode.img"

{
  echo "title   Arch Linux"
  echo "linux   /vmlinuz-linux"
  [[ -n "$UC_LINE" ]] && echo "$UC_LINE"
  echo "initrd  /initramfs-linux.img"
  echo "options cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot rw"
} > /mnt/boot/loader/entries/arch.conf

{
  echo "title   Arch Linux (fallback)"
  echo "linux   /vmlinuz-linux"
  [[ -n "$UC_LINE" ]] && echo "$UC_LINE"
  echo "initrd  /initramfs-linux-fallback.img"
  echo "options cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot rw"
} > /mnt/boot/loader/entries/arch-fallback.conf

echo "== Building initramfs =="
arch-chroot /mnt /bin/bash -e <<'CHROOT'
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
CHROOT

echo "== Creating swapfile =="
arch-chroot /mnt /bin/bash -e <<'CHROOT'
SWAP_GIB=8
if ! grep -q '^/swapfile ' /etc/fstab; then
  dd if=/dev/zero of=/swapfile bs=1M count=$(( SWAP_GIB * 1024 )) status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi
CHROOT

echo "== Creating user =="
arch-chroot /mnt /bin/bash -e <<CHROOT
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PW" | chpasswd
CHROOT

# --- SUCCESS ---
trap - EXIT
echo "Install done. Rebooting..."
reboot
