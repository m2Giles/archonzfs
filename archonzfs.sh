#!/bin/bash

set -e

ask () {
    read -p "> $1 " -r
    echo
}

passask () {
    while true; do
      echo
      echo "> $1"
      read -r -s PASS1
      echo
      echo "> Verify $1"
      read -r -s PASS2
      echo
      [ "$PASS1" = "$PASS2" ] && break || echo "Oops, please try again"
    done
    echo "$PASS2" > "$2"
    chmod 000 "$2"
    print "$1 can be reviewed at $2 prior to reboot"
    unset PASS1
    unset PASS2
}

umountandexport () {
    print "Umount all partitions"
    umount /mnt/efi
    zfs umount -a
    umount -R /mnt
    print "Export zpool"
    zpool export zroot
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
    while true; do
      ask "Size of EFI Partition in [MiB]. Minimum is 512 MiB:"
      if (( "$REPLY" >= 512 )); then break; else print "Oops. Too small, $REPLY is less than minimum is 512 [MiB]"; fi
    done
    sgdisk -n1:1M:+"$REPLY"M -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    ask "Do you want a Swap Partition?"
        if [[ $REPLY =~ ^[Yy]$ ]]
        then
          ask "Do you want Resume Support (Requires SWAP > MEMORY)?"
            if [[ $REPLY =~ ^[Yy]$ ]]; then
              SWAPRESUME=1
              SWAPMIN=$(free -h | sed -n '2p' | awk '{ print $2 }')
              SWAPMIN=$(( ${SWAPMIN::-2} + 2 ))
              while true; do
                ask "Size of Swap Partition in [GiB]? Minimum is $SWAPMIN GiB"
                if (( "$REPLY" >= "$SWAPMIN" )); then break;
                else
                  print "Oops. Too small, $REPLY GiB is less than minimum $SWAPMIN GiB for Resume Support"
                  ask "Do you wish to still have Resume Support?"
                  if [[ $CHECK =~ ^[Yy]$ ]]; then
                    SWAPRESUME=1
                  else
                    unset SWAPRESUME
                    ask "Size of Swap Partition in [GiB]?"
                    break
                  fi
                fi
              done
            else
              ask "Size of Swap Partition in [GiB]?"
            fi
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
  else
    if [[ -z "$EFI" || -z "$ZFS" ]]; then
      print "Export Partitions for EFI and ZFS installation locations and rerun script"
      print "Optionally export locations for Swap Partition and Swap DM name and Swap Resume for Swap Support"
      exit
    fi
  fi

if [[ -n $SWAPPART ]]; then
    print "Create Encrypted Swap"
    SWAP=/dev/mapper/swap
    passask "Swap LUKs Passphrase" "/tmp/swap.key"
    cryptsetup luksFormat --batch-mode --key-file=/tmp/swap.key "$SWAPPART"
    cryptsetup open --key-file=/tmp/swap.key "$SWAPPART" swap
    mkswap $SWAP
    swapon $SWAP
fi

# Set ZFS passphrase
print "Set ZFS passphrase for Encrypted Datasets"
passask "ZFS Passphrase" "/etc/zfs/zroot.key"

ask "Please enter hostname for Installation:" HOSTNAME

ask "Do you want SSH Access to ZFSBootMenu during Installation"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    ZFSREMOTE=1
  fi

print "Default Boot Choice is archlinux-linux.efi UKI\nKernel Command Line Editor is disabled, use ZFSBootMenu to edit KCL"
ask "Do you wish to change the Default Boot Choice during Installation?"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    CHANGEDEFAULT=1
  fi
ask "Would you like to sign EFI executables and enroll keys for Secureboot Support during Installation?"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    SECUREBOOT=1
  fi

ask "Do you want to unmount all partitions and export zpool after Installation?"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    UMOUNT=1
  fi

if [[ -n $UMOUNT ]]; then
  ask "Do you wish to reboot automatically following Installation?"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      AUTOREBOOT=1
    fi
fi

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
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/arch
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
zfs mount zroot/ROOT/arch
zfs mount -a
mkdir -p /mnt/efi
mount "$EFI" /mnt/efi
mkdir -p /mnt/efi/EFI/Linux

#Generate zfs hostid
print "Generate Hostid for ZFS"
zgenhostid -f "$(hostid)"

#Set Bootfs
print "Set ZFS bootfs"
zpool set bootfs=zroot/ROOT/arch zroot

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

print "Configure Pacman for Color and Parallel Downloads"
sed -i 's/#\(Color\)/\1/' /mnt/etc/pacman.conf
sed -i "/Color/a\\ILoveCandy" /mnt/etc/pacman.conf
sed -i 's/#\(Parallel\)/\1/' /mnt/etc/pacman.conf

# Copy Reflector Over
print "Copy Reflector Configuration"
cp /etc/xdg/reflector/reflector.conf /mnt/etc/xdg/reflector/reflector.conf
# FSTAB
print "Generate /etc/fstab and remove ZFS entries"
genfstab -U /mnt | grep -v "zroot" | tr -s '\n' | sed 's/\/mnt//'  > /mnt/etc/fstab

# Set Hostname and configure /etc/hosts
echo "$HOSTNAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
#<ip-address> <hostname.domaing.org>  <hostname>
127.0.0.1 localhost $HOSTNAME
::1       localhost $HOSTNAME
EOF

# Set and Prepare Locales
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
sed -i 's/#\(en_US.UTF-8\)/\1/' /mnt/etc/locale.gen

# mkinitcpio
print "mkinitcpio UKI configuration"
sed -i 's/HOOKS=/#HOOKS=/' /mnt/etc/mkinitcpio.conf
sed -i 's/FILES=/#FILES=/' /mnt/etc/mkinitcpio.conf
echo "FILES=(/keys/secret.jwe)" >> /mnt/etc/mkinitcpio.conf
if [[ -n "$SWAPRESUME" ]]; then
    echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard block clevis encrypt resume clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf
    CMDLINE="rw zfs=auto quiet udev.log_level=3 splash bgrt_disable cryptdevice=UUID=$(blkid $SWAPPART | awk '{ print $2 }' | cut -d\" -f 2):swap:allow-discards resume=$SWAP nowatchdog"
else
    echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard block clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf
    CMDLINE="rw zfs=auto quiet udev.log_level=3 splash bgrt_disable nowatchdog"
fi
echo "$CMDLINE" > /mnt/etc/kernel/cmdline

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
      print "TPM2 unlock of LUKs Swap Partition"
      cp /tmp/swap.key /mnt/keys/swap.key
      arch-chroot /mnt /bin/bash -xe << EOF
      pacman -Syu --noconfirm \
                  luksmeta    \
                  libpwquality\
                  tpm2-abrmd
      systemctl enable clevis-luks-askpass.path
      clevis-luks-bind -d "$SWAPPART" -k /keys/swap.key tpm2 '{}'
EOF
    shred /mnt/keys/swap.key
    rm /mnt/keys/swap.key
    cat >> /mnt/etc/crypttab << "EOF"
    swap UUID=$(blkid "$SWAPPART" | awk '{ print $2 }' | cut -d\" -f 2) none discard
EOF
    curl "https://raw.githubusercontent.com/kishorv06/arch-mkinitcpio-clevis-hook/main/hooks/clevis" -o /mnt/etc/initcpio/hooks/clevis
    curl "https://raw.githubusercontent.com/kishorv06/arch-mkinitcpio-clevis-hook/main/install/clevis" -o /mnt/etc/initcpio/install/clevis
fi

print "make AUR builder"
arch-chroot /mnt /bin/bash -xe << EOF
useradd -m builder
echo "builder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
sed -i 's/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/' /mnt/etc/makepkg.conf
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
    BootMountPoint: /efi
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
    Path: /boot/vmlinuz-linux-lts
    Prefix: zfsbootmenu
EOF
  print "Be sure to copy in ssh publickeys to /etc/dropbear/root_key for SSH access\n Dropbear will listen on port 2222 and use DHCP by default with this setup"
else
  cat > /mnt/etc/zfsbootmenu/config.yaml <<"EOF"
  Global:
    ManageImages: true
    BootMountPoint: /efi
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
    Path: /boot/vmlinuz-linux-lts
    Prefix: zfsbootmenu
EOF
fi

print "Make UKIs & ZFSBootMenu and Restore mkinitcpio pacman hooks"

mv /mnt/60-mkinitcpio-remove.hook /mnt/usr/share/libalpm/hooks/60-mkinitcpio-remove.hook
mv /mnt/90-mkinitcpio-install.hook /mnt/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
arch-chroot /mnt /bin/mkinitcpio -P
arch-chroot /mnt /bin/generate-zbm
arch-chroot /mnt /bin/generate-zbm
cat > /mnt/efi/loader/entries/zfsbootmenu.conf <<"EOF"
title ZFSBootMenu
efi   /EFI/zbm/zfsbootmenu.EFI
EOF
cat > /mnt/efi/loader/entries/zfsbootmenu-backup.conf <<"EOF"
title ZFSBootMenu (Backup)
efi   /EFI/zbm/zfsbootmenu-backup.EFI
EOF
if [[ -n "$CHANGEDEFAULT" ]]; then
    ls /mnt/efi/EFI/Linux/ >> /tmp/listboot
    ls /mnt/efi/loader/entries/ >> /tmp/listboot
    select ENTRY in $(cat /tmp/listboot);
    do
      echo "Setting $ENTRY as Default"
      ENTRY=$(echo "$ENTRY" | cut -d '.' -f1)
      cat > /mnt/efi/loader/loader.conf <<"EOF"
default "$ENTRY"
#timeout 3
console-mode max
editor no
EOF
      break
    done
  else
      cat > /mnt/efi/loader/loader.conf <<"EOF"
default archlinux-linux
#timeout 3
console-mode max
editor no
EOF
  fi

mkdir -p /mnt/pacman.d/hooks
cat > /mnt/pacman.d/hooks/95-systemd-boot.hook << "EOF"
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
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

if [[ -n $SECUREBOOT ]]; then
    print "Must have Secureboot in Setup Mode"
    arch-chroot /mnt /bin/bash -xe << EOF
    pacman -Syu sbctl --noconfirm
    sbctl status
EOF
    ask "Is Secureboot in Setup Mode?"
      if [[ $REPLY =~ ^[Yy]$ ]]; then
      ask "Do you wish to enroll Microsoft Keys as well for Option-ROM?"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          print "Generatng and Enrolling Keys with Microsoft Keys"
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
          systemctl enable systemd-boot-update.service
          sbctl status
EOF
          SECUREBOOTENABLED=1
        else
          print "Configure Secureboot Support on a later boot"
        fi
      fi
  fi

if [[ -n "$SECUREBOOTENABLED" && -n "$SWAPPART" ]]; then
  print "Bind LUKs Key and ZFS passphrase to Secureboot state on a later boot."
elif [[ -n "$SECUREBOOTENABLED" ]]; then
  print "Bind ZFS passphrase to Secureboot state on a later boot."
fi

print "Make Install Snapshot and Bootable Point\nThese are accessible from ZFSBootMenu"
zfs snapshot zroot/ROOT/arch@install
zfs clone zroot/ROOT/arch@install zroot/ROOT/arch_installpoint

if [[ -n "$UMOUNT" ]]; then
  umountandexport
  else
    ask "Do you want to unmount all partitions and export zpool?"
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        umountandexport
      else
        print "Be sure to unmount all partitions and export zpool before rebooting"
      fi
  fi

echo -e "\e[32mAll OK"

if [[ -n "$AUTOREBOOT" ]]; then
  count=5
  print "System will reboot automatically in $count Seconds. Cancel with CTRL+C"
  (( ++count ))
  while (( --count > 0 )); do
    echo "Reboot in $count Seconds"
    sleep 1
  done
  echo "Rebooting System"
  sleep 1
  reboot
fi
