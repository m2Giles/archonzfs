#!/bin/bash

set -e

ask () {
    read -p "> $1 " -r
    echo
}

# Get ZFS module on ISO
print "Getting ZFS Module"
curl -s https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init | bash

# Partition Drive
print "Choose Drive"
select ENTRY in $(ls /dev/disk/by-id);
do
  DISK="/dev/disk/by-id/$ENTRY"
  echo "$DISK" > /tmp/disk
  echo "Installing on $ENTRY"
  break
done

ask "Do you want to repartition $DISK?"
  if [[ $REPLY =~ ^[Yy]$ ]]
  then
    print "Partitioning Drive"
    # EFI Partition
    sgdisk -Zo "$DISK"
    ask "Size of EFI Partition in [M]?"
    sgdisk -n1:1M:+"$REPLY"M -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    # ZFS Partition
    sgdisk -n2:0:0 -t2:BF00 "$DISK"
    ZFS="$DISK-part2"

    # notify Kernel
    partprobe "$DISK"

    # Format EFI Partition
    sleep 1
    print "Formatting EFI Partition"
    mkfs.vfat "$EFI"
  fi

# Set ZFS passphrase
print "Set ZFS passphrase for Encrypted Datasets"
while true; do
  read -s -p "ZFS passphrase: " pass1
  echo
  read -s -p "Verify ZFS passphrase: " pass2
  echo
  [ "$pass1" = "$pass2" ] && break || echo "Oops, please try again"
done
echo "$pass2" > /etc/zfs/zroot.key
chmod 000 /etc/zfs/zroot.key
unset pass1
unset pass2

# Create ZFS pool
print "Create ZFS Pool"
zpool create -f -o ashift=12              \
                -o autotrim=on            \
                -O acltype=posixacl       \
                -O relatime=on            \
                -O xattr=sa               \
                -O dnodesize=legacy       \
                -O normalization=formD    \
                -O mountpoint=none        \
                -O canmount=off           \
                -O devices=off            \
                -R /mnt                   \
                -O compression=lz4        \
                -O encryption=aes-256-gcm \
                -O keyformat=passphrase   \
                -O keylocation=file:///etc/zfs/zroot.key     \
                zroot "$ZFS"

# Build Dataset Tree
print "Create Root Dataset"
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/default
print "Create Data Datasets"
zfs create -o mountpoint=none zroot/data
zfs create -o mountpoint=/home zroot/data/home
zfs create -o mountpoint=/root zroot/data/home/root
print "Create System Datasets"
zfs create -o mountpoint=/var -o canmount=off zroot/var
zfs create zroot/var/log
zfs create -o mountpoint=/var/lib -o canmount=off zroot/var/lib
zfs create zroot/var/lib/libvirt
zfs create zroot/var/lib/lxd

# Export and Reimport Pools
print "Export and Reimport Pools, mount partitions"
zpool export zroot
zpool import -d /dev/disk/by-id -R /mnt zroot -N

zfs load-key zroot
zfs mount zroot/ROOT/default
zfs mount -a
mkdir -p /mnt/efi
mount "$EFI" /mnt/efi
mkdir -p /mnt/efi/EFI/Linux

#Generate zfs hostid
print "Generate Hostid"
zgenhostid

#Set Bootfs
print "Set ZFS bootfs"
zpool set bootfs=zroot/ROOT/default zroot

#Zpool Cache
print "Create zpool cachefile"
mkdir -p /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache zroot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

# System Install
root_dataset=zroot/ROOT/default

# Sort Mirrors
print "Sorting Fastest Mirrors in US"
echo "--country US" >> /etc/xdg/reflector/reflector.conf
systemctl start reflector

# Install
print "Pacstrap"
pacstrap /mnt           \
      base              \
      base-devel        \
      linux-lts         \
      linux-lts-headers \
      linux-firmware    \
      intel-ucode       \
      neovim            \
      git               \
      reflector         \
      networkmanager    \
      clevis            \
      tpm2-tools        \
      openssh           \
      bash-completion

# Copy Reflector Over
cp /etc/xdg/reflector/reflector.conf /mnt/etc/xdg/reflector/reflector.conf
# FSTAB
print "Generate /etc/fstab and remove ZFS entries"
genfstab -U /mnt | grep -v "zroot" | tr -s '\n' | sed 's/\/mnt//'  > /mnt/etc/fstab

# Set Hostname and configure /etc/hosts
read -r -p 'Please enter hostname: ' hostname
echo "$hostname" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
#<ip-address> <hostname.domaing.org>  <hostname>
127.0.0.1 localhost $hostname
::1       localhost $hostname
EOF

# Set and Prepare Locales
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
sed -i 's/#\(en_US.UTF-8\)/\1/' /mnt/etc/locale.gen

# mkinitcpio
print "Barebones mkinitcpio uefi configuration"
sed -i 's/HOOKS=/#HOOKS=/' /mnt/etc/mkinitcpio.conf
sed -i 's/FILES=/#FILES=/' /mnt/etc/mkinitcpio.conf
echo "FILES=(/keys/secret.jwe)"
echo "HOOKS=(base udev autodetect modconf kms keyboard block clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf

cat > /mnt/etc/mkinitcpio.d/linux-lts.preset <<"EOF"
# mkinitcpio preset file for the 'linux-lts' package

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
ALL_microcode="/boot/intel-ucode.img"

PRESETS=('default' 'fallback')

#default_config="/etc/mkinitcpio.conf"
default_image="/boot/initramfs-linux-lts.img"
default_efi_image="/efi/EFI/Linux/archlinux-linux-lts.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

#fallback_config="/etc/mkinitcpio.conf"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_efi_image="/efi/EFI/Linux/archlinux-linux-lts-fallback.efi"
fallback_options="-S autodetect --splash /usr/share/systemd/bootctl/splash-arch.bmp"
EOF

echo "rw quiet nowatchdog zfs=auto" > /mnt/etc/kernel/cmdline

# Copy ZFS files
print "Copy ZFS files"
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# Systemd Resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolve.conf

# Add archzfs repo
cat >> /mnt/etc/pacman.conf << EOF
[archzfs]
Server = https://zxcvfdsa.com/archzfs/$repo/$arch
Server = http://archzfs.com/$repo/$arch
EOF

# Clevis TPM unlock preparation & getting hook
cp /etc/zfs/zroot.key /mnt/tmp/zroot.key
mkdir /mnt/keys
mkdir /mnt/etc/initcpio/{hooks,install}
print "Getting Clevis-Secret Hook"
curl -o "https://raw.githubusercontent.com/m2Giles/archonzfs/main/mkinitcpio/hooks/clevis-secret" /mnt/etc/initcpio/hooks/clevis-secret
curl -o "https://raw.githubusercontent.com/m2Giles/archonzfs/main/mkinitcpio/install/clevis-secret" /mnt/etc/initcpio/install/clevis-secret

# Chroot!
print "Chroot into System"
arch-chroot /mnt /bin/bash -xe << EOF
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman -Syu --noconfirm zfs-dkms zfs-utils
ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
hwclock --systohc
locale-gen
clevis-encrypt-tpm2 '{}' < /tmp/zroot.key > /keys/secret.jwe
mkinitcpio -P
bootctl install
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/zroot
zfs list -H -o name,mountpoint,canmount,atime,relatime,devices,exec,readonly,setuid,nbmand | sed 's/\/mnt//' > /etc/zfs/zfs-list.cache/zroot
systemctl enable    \
  NetworkManager    \
  systemd-resolved  \
  systemd-timesyncd \
  reflector.timer   \
  sshd              \
  zfs-import-cache  \
  zfs-mount         \
  zfs-import.target \
  zfs.target        \
  zfs-zed
EOF

# Set root passwd
arch-chroot /mnt /bin/passwd

# Umount
print "Umount all partitions"
umount /mnt/efi
zfs umount -a
umount -R /mnt

#Export Zpool
print "Export zpool"
zpool export zroot

echo "Done"
