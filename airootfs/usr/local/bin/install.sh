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

for i in "${!DISK_LINES[@]}"; do
  name="$(echo "${DISK_LINES[$i]}" | awk '{print $1}')"
  size="$(echo "${DISK_LINES[$i]}" | awk '{print $2}')"
  model="$(echo "${DISK_LINES[$i]}" | cut -d' ' -f3- | sed 's/  *disk .*//')"
  printf "[%d] %s  (%s, %s)\n" "$i" "$name" "$size" "$model"
done

read -rp "Select disk number to ERASE and install to: " IDX
[[ "$IDX" =~ ^[0-9]+$ ]] || die "Not a number."
(( IDX < ${#DISK_LINES[@]} )) || die "Out of range."

DISK="$(echo "${DISK_LINES[$IDX]}" | awk '{print $1}')"
echo
echo "Selected: $DISK"
echo "THIS WILL WIPE ALL DATA ON $DISK."
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || die "Aborted."

# --- passwords / user ---
read -rsp "LUKS password: " LUKS_PW; echo
read -rsp "Repeat LUKS password: " LUKS_PW2; echo
[[ "$LUKS_PW" == "$LUKS_PW2" ]] || die "LUKS passwords do not match."

read -rp "Username (will be created): " USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."

read -rsp "User password: " USER_PW; echo
read -rsp "Repeat user password: " USER_PW2; echo
[[ "$USER_PW" == "$USER_PW2" ]] || die "User passwords do not match."

# --- CPU microcode selection ---
UCPKG=""
if grep -qi 'GenuineIntel' /proc/cpuinfo; then
  UCPKG="intel-ucode"
elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  UCPKG="amd-ucode"
fi

# --- partition (UEFI) ---
echo "== Partitioning $DISK =="
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512MiB -t 1:EF00 -c 1:"EFI" "$DISK"
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

mkfs.fat -F32 "$EFI"

printf "%s" "$LUKS_PW" | cryptsetup luksFormat --type luks2 "$ROOT" -
printf "%s" "$LUKS_PW" | cryptsetup open "$ROOT" cryptroot -
unset LUKS_PW LUKS_PW2

mkfs.ext4 -F /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- install base system ---
PACSTRAP_PKGS=(base linux linux-firmware networkmanager sudo git)
[[ -n "$UCPKG" ]] && PACSTRAP_PKGS+=("$UCPKG")

pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# --- stash secrets AFTER pacstrap ---
SECRETS_DIR="/mnt/root/.install-secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
install -m 600 /dev/null "$SECRETS_DIR/chpasswd"
printf "%s:%s\n" "$USERNAME" "$USER_PW" > "$SECRETS_DIR/chpasswd"
unset USER_PW USER_PW2

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"

# --- base config ---
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
CHROOT

# --- bootloader ---
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

# --- mkinitcpio ---
arch-chroot /mnt /bin/bash -e <<'CHROOT'
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
CHROOT

# --- swapfile ---
arch-chroot /mnt /bin/bash -e <<'CHROOT'
SWAP_GIB=8
if ! grep -q '^/swapfile ' /etc/fstab; then
  dd if=/dev/zero of=/swapfile bs=1M count=$(( SWAP_GIB * 1024 )) status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi
CHROOT

# --- create user LAST ---
arch-chroot /mnt /bin/bash -e <<'CHROOT'
USERNAME="$(cut -d: -f1 /root/.install-secrets/chpasswd)"
useradd -m -G wheel "$USERNAME"
chpasswd < /root/.install-secrets/chpasswd
rm -f /root/.install-secrets/chpasswd
rmdir /root/.install-secrets 2>/dev/null || true
CHROOT

# --- SUCCESS ---
trap - EXIT
echo "✅ Install done. Rebooting is safe now."
