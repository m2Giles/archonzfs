#!/bin/bash

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
}

# Enable multilib
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

zfs create zroot/data/home/steamuser
zfs mount -a

print "update repos, install AMD vulkan drivers, install steam"
arch-chroot /mnt /bin/bash -xe << EOF
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
useradd steamuser
chown steamuser:steamuser /home/steamuser
chmod 0700 /home/steamuser
mkdir -p /home/steamuser/.config
cp -r /etc/xdg/openbox /home/steamuser/.config/
cat >> /home/steamuser/openbox/autostart << EOSF
unclutter --start-hidden &
while true
do
  steam -gamepadui
done
EOSF
EOF

cat > /mnt/home/steamuser/.xinitrc << EOF
#!/bin/sh

if [ -d /etc/X11/xinit/xinitrc.d ] ; then
 for f in /etc/X11/xinit/xinitrc.d/?*.sh ; do
  [ -x "$f" ] && . "$f"
 done
 unset f
fi

exec openbox-session
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

arch-chroot /mnt /bin/chown steamuser:steamuser -R /home/steamuser

mkdir /mnt/etc/systemd/system/getty@tty1.service.d/

cat > /mnt/etc/systemd/system/getty@tty1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin steamuser %I --noclear $TERM
EOF
