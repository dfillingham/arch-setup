#! /usr/bin/env bash

set -euo pipefail

echo "*** Available disks ***:"
lsblk -d -l -p
echo "***********************"

while true; do
    read -e -i "/dev/" -p "Input the disk to install to: " blkdisk
    devtype=$(lsblk -ndo type "$blkdisk" 2>/dev/null)
    if [[ "$devtype" == "disk" ]]; then
        break
    else
        echo "'$blkdisk' is not a disk"
    fi
done

while true; do
    read -p "Do you want to run cfdisk to partition the drive? [Y/n]: " yn
    case $yn in
        [Yy]|"" ) cfdisk "$blkdisk"; break;;
        [Nn] ) break;;
        * ) ;;
    esac
done

echo "*** Available partitions ***:"
lsblk -l -p "$blkdisk" | grep part
echo "***********************"

while true; do
    read -e -i "$blkdisk" -p "Input the partition for the EFI system partition: " blkdevefi
    devtype=$(lsblk -ndo type "$blkdevefi" 2>/dev/null)
    if [[ "$devtype" == "part" ]]; then
        break
    else
        echo "'$blkdevefi' is not a partition"
    fi
done

while true; do
    read -e -i "$blkdisk" -p "Input the partition for root filesystem: " blkdevroot
    devtype=$(lsblk -ndo type "$blkdevroot" 2>/dev/null)
    if [[ "$devtype" == "part" ]]; then
        break
    else
        echo "'$blkdevroot' is not a partition"
    fi
done


while true; do
    read -p "Do you want to sign bootables for SecureBoot? [Y/n]: " yn
    case $yn in
        [Yy]|"" ) USESECUREBOOT="yes"; break;;
        [Nn] ) USESECUREBOOT="no"; break;;
        * ) ;;
    esac
done

if [[ "$USESECUREBOOT" == "yes" ]]; then
    SBCTL_ENROLL_KEYS_OPTS=""

    while true; do
        read -p "Do you want to enroll Microsoft keys? [Y/n]: " yn
        case $yn in
            [Yy]|"" ) SBCTL_ENROLL_KEYS_OPTS="$SBCTL_ENROLL_KEYS_OPTS --microsoft"; break;;
            [Nn] ) break;;
            * ) ;;
        esac
    done

    while true; do
        read -p "Do you want to enroll vendor/firmware keys? [Y/n]: " yn
        case $yn in
            [Yy]|"" ) SBCTL_ENROLL_KEYS_OPTS="$SBCTL_ENROLL_KEYS_OPTS --firmware-builtin"; break;;
            [Nn] ) break;;
            * ) ;;
        esac
    done

fi

read -p "Input the hostname to use: " newhostname

echo "Setting up disk encryption..."
cryptsetup luksFormat "$blkdevroot"
cryptsetup open "$blkdevroot" root

echo "Formatting partitions..."
mkfs.btrfs /dev/mapper/root
mkfs.fat -F32 "$blkdevefi"

echo "Creating btfs subvolumes..."
mount /dev/mapper/root /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@log

umount /mnt

echo "Mounting subvolumes with proper options..."
mount --mkdir -o compress=zstd,ssd,space_cache=v2,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd,ssd,space_cache=v2,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd,ssd,space_cache=v2,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg
mount --mkdir -o compress=zstd,ssd,space_cache=v2,subvol=@log /dev/mapper/root /mnt/var/log

devuuid=$(blkid -s UUID -o value "$blkdevroot")

echo "Mounting EFI system partition..."
mount --mkdir "$blkdevefi" /mnt/efi

echo "Updating mirrorlist..."
reflector --country Australia --threads 5 --save /etc/pacman.d/mirrorlist --protocol https --score 5

echo "Adding cache server to mirror list..."
echo 'CacheServer = http://arch-pkg-cache.in.fillingham.au/repo/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist

echo "Pacstrapping..."
pacstrap -K /mnt base

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Setting up systemd-resolved stub symlink..."
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

echo "Installing packages..."
arch-chroot /mnt pacman -S --needed --noconfirm - < ./packages.txt

echo "Copying config files..."
cp -r ./config/base/. /mnt

echo "Ensuring databases and packages are up to date"
arch-chroot /mnt pacman -Syu --needed --noconfirm

echo "Setting hostname..."
sed -i "s/{{HOSTNAME}}/${newhostname}/g" /mnt/etc/hosts
echo "$newhostname" > /mnt/etc/hostname

echo "Setting device UUID in kernel cmdline..."
sed -i "s/{{DEVUUID}}/${devuuid}/g" /mnt/etc/kernel/cmdline

echo "Setting timezone..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Australia/Brisbane /etc/localtime
arch-chroot /mnt hwclock --systohc

echo "Generating locales..."
arch-chroot /mnt locale-gen

echo "Enabling NTP..."
arch-chroot /mnt timedatectl set-ntp true

if [[ "$USESECUREBOOT" == "yes" ]]; then
    echo "Setting up secureboot..."
    arch-chroot /mnt sbctl create-keys
    arch-chroot /mnt sbctl enroll-keys "$SBCTL_ENROLL_KEYS_OPTS"
    arch-chroot /mnt sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
fi


# Ensure directory exists to land UKI in
echo "Building UKI..."
arch-chroot /mnt mkdir -p /efi/EFI/Linux
arch-chroot /mnt mkinitcpio -P

# An initramfs is created in /boot by the pacman hook when `linux` is first installed
echo "Cleaning up leftover initramfs..."
rm -f /mnt/boot/initramfs-linux.img

echo "Installing bootloader..."
arch-chroot /mnt bootctl install

echo "Setting root password to 'password'..."
echo "password" | arch-chroot /mnt passwd --stdin

echo "Enabling services..."
systemctl --root=/mnt enable \
  firewalld.service \
  fstrim.timer \
  NetworkManager.service \
  NetworkManager-dispatcher.service \
  libvirtd.socket \
  linux-modules-cleanup.service \
  plasmalogin.service \
  power-profiles-daemon.service \
  sshd.service \
  systemd-boot-update.service \
  systemd-resolved.service \
  systemd-timesyncd.service \
  virtlogd.socket

# Setup KMSCON
systemctl --root=/mnt disable getty@.service
systemctl --root=/mnt enable kmsconvt@.service
systemctl --root=/mnt disable getty@tty1.service
systemctl --root=/mnt enable kmsconvt@tty1.service

echo "Creating EFI boot entry for UKI..."
efibootmgr -c -L "Arch Linux" -l '\EFI\Linux\arch-linux.efi' -d "$blkdisk"

echo "Basic installation completed!"

while true; do
    read -p "Do you want to do the domain join? [Y/n]: " yn
    case $yn in
        [Yy]|"" ) break;;
        [Nn] ) echo "You can now reboot! Don't forget to change the root user's password!"; exit 0;;
        * ) ;;
    esac
done

echo "Copying config files..."
cp -r ./config/join-domain/. /mnt

systemctl --root=/mnt enable smb winbind

echo "Setting permissions on NetworkManager dispatch script..."
arch-chroot /mnt chown root:root /etc/NetworkManager/dispatcher.d/20-winbind
arch-chroot /mnt chmod +x /etc/NetworkManager/dispatcher.d/20-winbind

read -p "Enter the username of the account with permission to domain join: " djaccount
arch-chroot /mnt net ads join -U "$djaccount"

# wbinfo -u blocks until winbindd is actually ready, ensuring that nsswitch
# can find the user when adding to wheel group
read -p "Enter the domain user username to add to the wheel group locally, leave blank to skip: " domuser
if [[ ! -z "$domuser" ]]; then
    arch-chroot /mnt bash <<EOF
smbd -D
winbindd -D
wbinfo -u > /dev/null
id "$domuser"
usermod -aG wheel "$domuser"
EOF

fi

echo "You can now reboot! Don't forget to change the root user's password!"
