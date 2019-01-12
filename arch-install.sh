#!/bin/sh

source install.conf

mkfs.vfat -F 32 -n Boot $BOOT_PART
mkfs.btrfs -L System $SYSTEM_PART

mount $SYSTEM_PART $MNT
btrfs subvolume create $MNT/system
btrfs subvolume create $MNT/system-backup
btrfs subvolume create $MNT/pkg

umount $MNT

mount $SYSTEM_PART -o subvol=system $MNT
mkdir $MNT/boot
mkdir -p $MNT/var/cache/pacman/pkg
mount $BOOT_PART $MNT/boot
mount $SYSTEM_PART -o subvol=pkg $MNT/var/cache/pacman/pkg
pacstrap $MNT base base-devel btrfs-progs zsh grml-zsh-config $DESKTOP $BROWSER $VIDEO

echo "$HOSTNAME" | awk '{print tolower($0)}' > $MNT/hostname
sed -e "s/^\(NAME\s*=\s*\).*$/\1"$HOSTNAME"/" -i $MNT/etc/os-release
sed -e "s/^\(PRETTY_NAME\s*=\s*\).*$/\1"$HOSTNAME"/" -i $MNT/etc/os-release
sed -e "s/^\(ANSI_COLOR\s*=\s*\).*$/\1"$COLOR"/" -i $MNT/etc/os-release

# language and region
echo "KEYMAP=de-latin1" > $MNT/etc/vconsole.conf

for l in ${GENERATION_LANGS[*]}; do
	sed -e "/$l/ s/^#*//" -i $MNT/etc/locale.gen
done

echo "LANG=$LANG" > $MNT/etc/locale.conf
echo "LANGUAGE=$LANGUAGE" >> $MNT/etc/locale.conf

ln -sf /usr/share/$TIMEZONE $MNT/etc/localtime

# pacman and makepkg
sed -e "/Color/ s/^#*//" -i $MNT/etc/pacman.conf
sed -e "/TotalDownload/ s/^#*//" -i $MNT/etc/pacman.conf

sed -e "s/^\(MAKEFLAGS\s*=\s*\).*$/\1"-j$((1+$(cat /proc/cpuinfo | grep processor | wc -l)))"/" -i $MNT/etc/makepkg.conf 
