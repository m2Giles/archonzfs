#!/bin/bash

set -e

ask () {
    read -p "> $1 " -r
    echo
}

# Get ZFS module on ISO
echo "Getting ZFS Module"
curl -s https://raw.githubusercontent.com/eoli3n/archiso-zfs/master/init | bash

# Partition Drive
echo "Choose Drive"
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
    echo "Partitioning Drive"
    # EFI Partition
    sgdisk -Zo "$DISK"
    ask "Size of EFI Partition in [M]?"
    sgdisk -n1:1M:+"$REPLY"M -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    ask "Do you want SWAP Partition?"
        if [[ $REPLY =~ ^[Yy]$ ]]
        then
            ask "Size of SWAP Partition in [G]"
            sgdisk -n2:0:+"$REPLY"G -t2:8200 "$DISK"
            SWAPPART="$DISK-part2"
        fi

    # ZFS Partition
    sgdisk -n3:0:0 -t3:BF00 "$DISK"
    ZFS="$DISK-part3"

    # notify Kernel
    partprobe "$DISK"

    # Format EFI Partition
    sleep 1
    echo "Formatting EFI Partition"
    mkfs.vfat -F32 "$EFI"
  fi

if [[ -n $SWAPPART ]]
then
    echo "Create Encrypted SWAP"
    SWAP=/dev/mapper/swap
    cryptsetup luksFormat "$SWAPPART"
    cryptsetup open "$SWAPPART" swap
    mkswap $SWAP
    swapon $SWAP
fi

# Set ZFS passphrase
echo "Set ZFS passphrase for Encrypted Datasets"
while true; do
  read -s -p -r "ZFS passphrase: " pass1
  echo
  read -s -p -r "Verify ZFS passphrase: " pass2
  echo
  [ "$pass1" = "$pass2" ] && break || echo "Oops, please try again"
done
echo "$pass2" > /etc/zfs/zroot.key
chmod 000 /etc/zfs/zroot.key
unset pass1
unset pass2

# Create ZFS pool
echo "Create ZFS Pool"
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
echo "Create Root Dataset"
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/default
echo "Create Data Datasets"
zfs create -o mountpoint=none zroot/data
zfs create -o mountpoint=/home zroot/data/home
zfs create -o mountpoint=/root zroot/data/home/root
echo "Create System Datasets"
zfs create -o mountpoint=/var -o canmount=off zroot/var
zfs create zroot/var/log
zfs create -o mountpoint=/var/lib -o canmount=off zroot/var/lib
zfs create zroot/var/lib/libvirt
zfs create zroot/var/lib/lxd

# Export and Reimport Pools
echo "Export and Reimport Pools, mount partitions"
zpool export zroot
zpool import -d /dev/disk/by-id -R /mnt zroot -N

zfs load-key zroot
zfs mount zroot/ROOT/default
zfs mount -a
mkdir -p /mnt/efi
mount "$EFI" /mnt/efi
mkdir -p /mnt/efi/EFI/Linux

#Generate zfs hostid
echo "Generate Hostid"
zgenhostid

#Set Bootfs
echo "Set ZFS bootfs"
zpool set bootfs=zroot/ROOT/default zroot

#Zpool Cache
echo "Create zpool cachefile"
mkdir -p /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache zroot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

# Sort Mirrors
echo "Sorting Fastest Mirrors in US"
echo "--country US" >> /etc/xdg/reflector/reflector.conf
systemctl start reflector

# Install
echo "Pacstrap"
pacstrap /mnt           \
      base              \
      base-devel        \
      linux             \
      linux-headers     \
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
echo "Generate /etc/fstab and remove ZFS entries"
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
echo "Barebones mkinitcpio uefi configuration"
sed -i 's/HOOKS=/#HOOKS=/' /mnt/etc/mkinitcpio.conf
sed -i 's/FILES=/#FILES=/' /mnt/etc/mkinitcpio.conf
echo "FILES=(/keys/secret.jwe)" >> /mnt/etc/mkinitcpio.conf
if [[ -n $SWAPPART ]]
then
    ask "Do you want Resume Support (SWAP > MEMORY)?"
    if [[ $REPLY =~ ^[Yy]$ ]]
        then
            SWAPRESUME=1
            pacstrap /mnt       \
            luksmeta            \
            libpwquality        \
            tpm2-abmrd
            echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard block clevis encrypt resume clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf
        else
            echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard block clevis encrypt clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf
    fi
else
    echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard block clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf
fi

cat > /mnt/etc/mkinitcpio.d/linux-lts.preset <<"EOF"
# mkinitcpio preset file for the 'linux-lts' package

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
ALL_microcode="/boot/intel-ucode.img"

PRESETS=('default' 'fallback')

#default_config="/etc/mkinitcpio.conf"
default_image="/boot/initramfs-linux-lts.img"
default_uki="/efi/EFI/Linux/archlinux-linux-lts.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

#fallback_config="/etc/mkinitcpio.conf"
fallback_image="/boot/initramfs-linux-lts-fallback.img"
fallback_uki="/efi/EFI/Linux/archlinux-linux-lts-fallback.efi"
fallback_options="-S autodetect --splash /usr/share/systemd/bootctl/splash-arch.bmp"
EOF

cat > /mnt/etc/mkinitcpio.d/linux.preset <<"EOF"
# mkinitcpio preset file for the 'linux' package

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
ALL_microcode="/boot/intel-ucode.img"

PRESETS=('default' 'fallback')

#default_config="/etc/mkinitcpio.conf"
default_image="/boot/initramfs-linux.img"
default_uki="/efi/EFI/Linux/archlinux-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

#fallback_config="/etc/mkinitcpio.conf"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_uki="/efi/EFI/Linux/archlinux-linux-fallback.efi"
fallback_options="-S autodetect --splash /usr/share/systemd/bootctl/splash-arch.bmp"
EOF

echo "rw zfs=auto quiet udev.log_level=3 splash bgrt_disable nowatchdog" > /mnt/etc/kernel/cmdline

if [[ -n $SWAPPART ]]; then
    echo "rw zfs=auto quiet udev.log_level=3 splash bgrt_disable cryptdevice=UUID=$(blkid $SWAP | awk '{ print $2 }' | cut -d\" -f 2):swap nowatchdog" > /mnt/etc/kernel/cmdline
fi

if [[ -n $SWAPRESUME ]]; then
    echo "rw zfs=auto quiet udev.log_level=3 splash bgrt_disable cryptdevice=UUID=$(blkid $SWAP | awk '{ print $2 }' | cut -d\" -f 2):swap resume=$SWAP nowatchdog" > /mnt/etc/kernel/cmdline
fi
# Copy ZFS files
echo "Copy ZFS files"
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# Systemd Resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolve.conf

# Add archzfs repo
cat >> /mnt/etc/pacman.conf << EOF
[archzfs]
Server = https://zxcvfdsa.com/archzfs/archzfs/x86_64
Server = http://archzfs.com/archzfs/x86_64
EOF

# Clevis TPM unlock preparation & getting hook
mkdir /mnt/keys
cp /etc/zfs/zroot.key /mnt/keys/zroot.key
echo "Getting Clevis-Secret Hook"
curl "https://raw.githubusercontent.com/m2Giles/archonzfs/main/mkinitcpio/hooks/clevis-secret" -o /mnt/etc/initcpio/hooks/clevis-secret
curl "https://raw.githubusercontent.com/m2Giles/archonzfs/main/mkinitcpio/install/clevis-secret" -o /mnt/etc/initcpio/install/clevis-secret

if [[ -n $SWAPPART ]]; then
    curl "https://github.com/kishorv06/arch-mkinitcpio-clevis-hook/blob/main/hooks/clevis" -o /mnt/etc/initcpio/hooks/clevis
    curl "https://github.com/kishorv06/arch-mkinitcpio-clevis-hook/blob/main/install/clevis" -o /mnt/etc/initcpio/install/clevis
fi

echo "make AUR builder"
arch-chroot /mnt /bin/bash -xe << EOF
useradd -m builder
echo "builder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
EOF

echo "Build Plymouth and configure"
arch-chroot /mnt /usr/bin/su -l builder -c "/bin/bash -xe << EOF
git clone https://aur.archlinux.org/plymouth-git
cd /home/builder/plymouth-git
makepkg -si --noconfirm
EOF"

cp /mnt/usr/share/plymouth/arch-logo.png /mnt/usr/share/plymouth/themes/spinner/watermark.png
sed -i 's/WatermarkVerticalAlignment=.96/WatermarkVerticalAlignment=.5' /mnt/usr/share/plymouth/themes/spinner/spinner.plymouth
echo "DeviceScale=1" >> /mnt/etc/plymouth/plymouthd.conf


# Chroot!
echo "Chroot into System"
arch-chroot /mnt /bin/bash -xe << EOF
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman -Syu --noconfirm zfs-dkms zfs-utils
ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
hwclock --systohc
locale-gen
clevis-encrypt-tpm2 '{}' < /keys/zroot.key > /keys/secret.jwe
shred /keys/zroot.key
rm /keys/zroot.key
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

if [[ -n $SWAP ]]
    then
    arch-chroot /mnt /bin/clevis-luks-bind -d "$SWAPPART" tpm2 '{}'
fi

# Set root passwd
arch-chroot /mnt /bin/passwd

ask "Do you want to chroot??"
  if [[ $REPLY =~ ^[Yy]$ ]]
  then
  arch-chroot /mnt
fi


# Umount
echo "Umount all partitions"
umount /mnt/efi
zfs umount -a
umount -R /mnt

#Export Zpool
echo "Export zpool"
zpool export zroot

echo "Done"
