#!/bin/bash

set -e

ask () {
    read -p "> $1 " -r
    echo
}

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
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
            sgdisk -n2:0:+"$REPLY"G -t2:8200 -A 2:set:63 "$DISK"
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
    print "Create Encrypted SWAP"
    SWAP=/dev/mapper/swap
    while true; do
      read -s -p "SWAP LUKs passphrase: " pass1
      echo
      read -s -p "SWAP LUKs passphrase: " pass2
      echo
      [ "$pass1" = "$pass2" ] && break || echo "Oops, please try again"
    done
    echo "$pass2" > /tmp/swap.key
    unset pass1
    unset pass2
    cryptsetup luksFormat --batch-mode --key-file=/tmp/swap.key "$SWAPPART"
    print "Open Encrypted SWAP Container"
    cryptsetup open --key-file=/tmp/swap.key "$SWAPPART" swap
    mkswap $SWAP
    swapon $SWAP
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

# Sort Mirrors
print "Sorting Fastest Mirrors in US"
echo "--country US" >> /etc/xdg/reflector/reflector.conf
systemctl start reflector

# Install
print "Pacstrap"
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

# Mask mkinitcpio Hook to Speed up installs
print "Move mkinitcpio pacman Hooks to speed up installs"
mv /mnt/usr/share/libalpm/hooks/60-mkinitcpio-remove.hook /mnt/60-mkinitcpio-remove.hook
mv /mnt/usr/share/libalpm/hooks/90-mkinitcpio-install.hook /mnt/90-mkinitcpio-install.hook

# Copy Reflector Over
print "Copy Reflector Configuration"
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
print "mkinitcpio UKI configuration"
sed -i 's/HOOKS=/#HOOKS=/' /mnt/etc/mkinitcpio.conf
sed -i 's/FILES=/#FILES=/' /mnt/etc/mkinitcpio.conf
echo "FILES=(/keys/secret.jwe)" >> /mnt/etc/mkinitcpio.conf
if [[ -n $SWAPPART ]]
then
    ask "Do you want Resume Support (SWAP > MEMORY)?"
    if [[ $REPLY =~ ^[Yy]$ ]]
        then
            SWAPRESUME=1
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

CMDLINE="rw zfs=auto quiet udev.log_level=3 splash bgrt_disable nowatchdog"
echo "$CMDLINE" > /mnt/etc/kernel/cmdline

# Copy ZFS files
print "Copy ZFS files"
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
print "TPM2 unlock of zfs root dataset"
mkdir /mnt/keys
cp /etc/zfs/zroot.key /mnt/keys/zroot.key
print "Getting Clevis-Secret Hook"
curl "https://raw.githubusercontent.com/m2Giles/archonzfs/main/mkinitcpio/hooks/clevis-secret" -o /mnt/etc/initcpio/hooks/clevis-secret
curl "https://raw.githubusercontent.com/m2Giles/archonzfs/main/mkinitcpio/install/clevis-secret" -o /mnt/etc/initcpio/install/clevis-secret

if [[ -n $SWAPPART ]]; then
     pacstrap /mnt       \
            luksmeta            \
            libpwquality        \
            tpm2-abrmd
    curl "https://raw.githubusercontent.com/kishorv06/arch-mkinitcpio-clevis-hook/main/hooks/clevis" -o /mnt/etc/initcpio/hooks/clevis
    curl "https://raw.githubusercontent.com/kishorv06/arch-mkinitcpio-clevis-hook/main/install/clevis" -o /mnt/etc/initcpio/install/clevis
    cp /tmp/swap.key /mnt/keys/swap.key
    arch-chroot /mnt /bin/clevis-luks-bind -d "$SWAPPART" -k /keys/swap.key tpm2 '{}'
    shred /mnt/keys/swap.key
    rm /mnt/keys/swap.key
    if [[ -n $SWAPRESUME ]]; then
        CMDLINE="rw zfs=auto quiet udev.log_level=3 splash bgrt_disable cryptdevice=UUID=$(blkid $SWAPPART | awk '{ print $2 }' | cut -d\" -f 2):swap:allow-discards resume=$SWAP nowatchdog"
        echo "$CMDLINE" > /mnt/etc/kernel/cmdline
    else
        CMDLINE="rw zfs=auto quiet udev.log_level=3 splash bgrt_disable cryptdevice=UUID=$(blkid $SWAPPART | awk '{ print $2 }' | cut -d\" -f 2):swap:allow-discards nowatchdog"
        echo "$CMDLINE" > /mnt/etc/kernel/cmdline
    fi
fi

print "make AUR builder"
arch-chroot /mnt /bin/bash -xe << EOF
useradd -m builder
echo "builder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
EOF

print "Build Plymouth and configure"
arch-chroot /mnt /usr/bin/su -l builder -c "/bin/bash -xe << EOF
git clone https://aur.archlinux.org/paru-bin
cd /home/builder/paru-bin
makepkg -si --noconfirm
cd /home/builder
paru -S plymouth-git --noconfirm
EOF"

cp /mnt/usr/share/plymouth/arch-logo.png /mnt/usr/share/plymouth/themes/spinner/watermark.png
sed -i 's/.96/.5/' /mnt/usr/share/plymouth/themes/spinner/spinner.plymouth
echo "DeviceScale=1" >> /mnt/etc/plymouth/plymouthd.conf

# Chroot!
print "Chroot into System"
arch-chroot /mnt /bin/bash -xe << EOF
clevis-encrypt-tpm2 '{}' < /keys/zroot.key > /keys/secret.jwe
shred /keys/zroot.key
rm /keys/zroot.key
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman -Syu --noconfirm zfs-dkms zfs-utils
ln -sf /usr/share/zoneinfo/US/Eastern /etc/localtime
hwclock --systohc
locale-gen
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

print "Install ZFSBootMenu"
ask "Do you want SSH Access to ZFSBootMenu"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    ZFSREMOTE=1
  fi
if [[ -n "$ZFSREMOTE" ]]; then
  arch-chroot /mnt /usr/bin/su -l builder -c "/bin/bash -xe << EOF
  paru -S mkinitcpio-netconf mkinitcpio-utils dropbear zfsbootmenu --noconfirm
EOF"
else
  arch-chroot /mnt /usr/bin/su -l builder -c "/bin/bash -xe << EOF
  paru -S zfsbootmenu --noconfirm
EOF"
fi

zfs set org.zfsbootmenu:commandline="$CMDLINE" zroot/ROOT

print "Configure ZFSBootMenu"
if [[ -n "$ZFSREMOTE" ]]; then
  print "Be sure to copy in ssh publickeys to /etc/dropbear/root_key for SSH access\n Dropbear will listen on port 2222 and use DHCP by default with this setup"
  mkdir -p /mnt/etc/zfsbootmenu/initcpio/{hooks,install}
  curl "https://raw.githubusercontent.com/ahesford/mkinitcpio-dropbear/master/dropbear_hook" -o /mnt/etc/zfsbootmenu/initcpio/hooks/dropbear
  curl "https://raw.githubusercontent.com/ahesford/mkinitcpio-dropbear/master/dropbear_install" -o /mnt/etc/zfsbootmenu/initcpio/install/dropbear
  mkdir -p /mnt/etc/dropbear
  arch-chroot /mnt /bin/bash -xe << "EOF"
  for keytype in rsa ecdsa ed25519; do
    dropbearkey -t "${keytype}" -f "/etc/dropbear/dropbear_${keytype}_host_key"
  done
  touch /etc/dropbear/root_key
  echo "dropbear_listen=2222" > /etc/dropbear/dropbear.conf
EOF
  sed -i 's/HOOKS=/#HOOKS=/' /mnt/etc/zfsbootmenu/mkinitcpio.conf
  echo "HOOKS=(base udev autodetect modconf block filesystems keyboard netconf dropbear zfsbootmenu)" >> /mnt/etc/zfsbootmenu/mkinitcpio.conf
  cat > /mnt/etc/zfsbootmenu/config.yaml <<"EOF"
  Global:
    ManageImages: true
    InitCPIO: true
    InitCPIOConfig: /etc/zfsbootmenu/mkinitcpio.conf
    InitCPIOHookDirs:
      - /etc/zfsbootmenu/initcpio
      - /usr/lib/initcpio
  EFI:
    ImageDir: /efi/EFI/zbm
    Versions: false
    Enabled: true
  Kernel:
    CommandLine: ro quiet loglevel=0 ip=dhcp zbm.show
    Prefix: zfsbootmenu
EOF
  print "Be sure to copy in ssh publickeys to /etc/dropbear/root_key for SSH access\n Dropbear will listen on port 2222 and use DHCP by default with this setup"
else
  cat > /mnt/etc/zfsbootmenu/config.yaml <<"EOF"
  Global:
    ManageImages: true
    InitCPIO: true
    InitCPIOConfig: /etc/zfsbootmenu/mkinitcpio.conf
    InitCPIOHookDirs:
      - /etc/zfsbootmenu/initcpio
      - /usr/lib/initcpio
  EFI:
    ImageDir: /efi/EFI/zbm
    Versions: false
    Enabled: true
  Kernel:
    CommandLine: ro quiet loglevel=0 zbm.show
    Prefix: zfsbootmenu
EOF
fi

print "Make UKIs & ZFSBootMenu and Restore mkinitcpio pacman hooks"

mv /mnt/60-mkinitcpio-remove.hook /mnt/usr/share/libalpm/hooks/60-mkinitcpio-remove.hook
mv /mnt/90-mkinitcpio-install.hook /mnt/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
arch-chroot /mnt /bin/mkinitcpio -P
arch-chroot /mnt /bin/generate-zbm
arch-chroot /mnt /bin/generate-zbm
cat > /mnt/efi/loader/entries/zbm.conf <<"EOF"
title ZFSBootMenu
efi   /EFI/zbm/zfsbootmenu.EFI
EOF
cat > /mnt/efi/loader/entries/zbm-backup.conf <<"EOF"
title ZFSBootMenu (Backup)
efi   /EFI/zbm/zfsbootmenu-backup.EFI
EOF

print "Cleanup AUR Builder"
arch-chroot /mnt /bin/bash -xe << EOF
userdel builder
rm /etc/sudoers.d/builder
rm -rf /home/builder
EOF

# Set root passwd
print "Set Root Account Password"
arch-chroot /mnt /bin/passwd

ask "Would you like to sign EFI executables and enroll keys for Secureboot Support?"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    print "Must have Secureboot in Setup Mode"
    pacstrap /mnt sbctl
    arch-chroot /mnt /bin/bash -xe << EOF
    sbctl status
EOF
    ask "Is Secureboot in Setup Mode?"
      if [[ $REPLY =~ ^[Yy]$ ]]
      then
        print "Generate and Enroll-Keys with microsoft vendor keys"
        arch-chroot /mnt /bin/bash -xe << EOF
        sbctl create-keys
        sbctl enroll-keys --microsoft
        sbctl sign -s /efi/EFI/Linux/archlinux-linux.efi
        sbctl sign -s /efi/EFI/Linux/archlinux-linux-lts.efi
        sbctl sign -s /efi/EFI/Linux/archlinux-linux-fallback.efi
        sbctl sign -s /efi/EFI/Linux/archlinux-linux-lts-fallback.efi
        sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
        sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
        sbctl sign -s /efi/EFI/zbm/zfsbootmenu.EFI
        sbctl sign -s /efi/EFI/zbm/zfsbootmenu-backup.EFI
        sbctl verify
EOF
      secureboot=1
      else
        print "Configure Secureboot Support on a later boot"
      fi
    fi
if [[ -n "$secureboot" ]]; then
    arch-chroot /mnt /bin/bash -xe << EOF
    sbctl status
EOF
  ask "Do you wish to bind tpm2 unlocks to tpm2 measurements? (Secureboot must be enabled)"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      cp /etc/zfs/zroot.key /mnt/keys/zroot.key
      if [[ -f /tmp/swap.key ]]; then
        cp /tmp/swap.key /mnt/keys/swap.key
        arch-chroot /mnt /bin/clevis-luks-unbind -d "$SWAPPART" -s 1 -f
        arch-chroot /mnt /bin/clevis-luks-bind -d "$SWAPPART" -k /keys/swap.key tpm2 '{"pcr_bank":"sha256","pcr_ids":"1,7"}'
        shred /mnt/keys/swap.key
        rm /mnt/keys/swap.key
      fi
        arch-chroot /mnt /bin/clevis-encrypt-tpm2 '{"pcr_bank":"sha256","pcr_ids":"1,7"}' < /keys/zroot.key > /keys/secret.jwe
        shred /mnt/keys/zroot.key
        rm /mnt/keys/zroot.key
    fi
fi


print "Make Install Snapshot"
zfs snapshot zroot/ROOT/default@install

ask "Do you want to chroot?"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    arch-chroot /mnt /bin/bash
  fi

ask "Do you want to unmount all partitions and export zpool?"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    print "Umount all partitions"
    umount /mnt/efi
    zfs umount -a
    umount -R /mnt
    print "Export zpool"
    zpool export zroot
  fi

echo -e "\e[32mAll OK"
