#!/bin/bash

# Enable multilib
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

print "make builder, update repos, install amd vulkan drivers, install steam"
arch-chroot /mnt /bin/bash -xe << EOF
useradd -m builder
echo "builder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
pacman -Syu --noconfirm
pacman -Syu --noconfirm             \
            vulkan-radeon           \
            lib32-vulkan-radeon     \
            pipewire pipewire-alsa  \
            pipewire-pulse          \
            pipewire-jack           \
            wireplumber             \
            openbox                 \
            xorg-xinit              \
            unclutter               \
            steam
EOF

# Build plymouth
print "Build Plymouth and configure"
arch-chroot /mnt /usr/bin/su -l builder -c "/bin/bash -xe << EOF
git clone https://aur.archlinux.org/plymouth-git
makepkg -si --noconfirm
EOF"
cp /mnt/usr/share/plymouth/arch-logo.png /mnt/usr/share/plymouth/themes/spinner/watermark.png
sed -i 's/VerticalAlignment=.96/VerticalAlignment=.5'

echo "rw zfs=auto quiet log_level=3 udev.log_level=3 splash bgrt_disable" > /mnt/etc/kernel/cmdline
sed -i 's/HOOKS=/#HOOKS=/' /mnt/etc/mkinitcpio.conf
echo "HOOKS=(base udev plymouth autodetect modconf kms keyboard block clevis-secret zfs filesystems)" >> /mnt/etc/mkinitcpio.conf

# Remake initramfs and cleanup builder
print "Rebuild initramfs, cleanup builder"
arch-chroot /mnt /bin/bash -xe << EOF
mkinitcpio -P
userdel builder
EOF

rm /mnt/etc/sudoers.d/builder
rm -rf /mnt/home/builder

# Create steamuser, setup auto-login and startx
arch-chroot /mnt /bin/bash -xe << EOF
useradd -m steamuser
EOF

cat > /mnt/home/steamuser/.xinitrc << EOF
#!/bin/sh

userresources=$HOME/.Xresources
usermodmap=$HOME/.Xmodmap
sysresources=/etc/X11/xinit/.Xresources
sysmodmap=/etc/X11/xinit/.Xmodmap

# merge in defaults and keymaps

if [ -f $sysresources ]; then
    xrdb -merge $sysresources
fi

if [ -f $sysmodmap ]; then
    xmodmap $sysmodmap
fi

if [ -f "$userresources" ]; then
    xrdb -merge "$userresources"

fi

if [ -f "$usermodmap" ]; then
    xmodmap "$usermodmap"
fi

# start some nice programs

if [ -d /etc/X11/xinit/xinitrc.d ] ; then
 for f in /etc/X11/xinit/xinitrc.d/?*.sh ; do
  [ -x "$f" ] && . "$f"
 done
 unset f
fi

unclutter --start-hidden &
openbox-session &
exec steam -gamepadui
EOF

mkdir /mnt/etc/systemd/system/getty@tty1.service.d/

cat > /mnt/etc/systemd/system/getty@tty1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin steamuser %I --noclear $TERM
EOF

cat > /mnt/home/steamuser/.bash_profile << EOF
#
# ~/.bash_profile
#

[[ -f ~/.bashrc ]] && . ~/.bashrc

if [ -z $DISPLAY ] && [ "$(tty)" = "/dev/tty1" ]; then
        exec startx -- -keeptty >~/.xorg.log 2>&1
fi
EOF
