#!/bin/sh
#
# ============== #
#   Arch Linux   #
# ============== #
#
# Short install guide / script for Arch Linux with LUKS encryption and BTRFS partitions
#
# @authors @Eiskasten, @re1
# @version 2018-11-03

source install.conf		# load install script configuration


# ---------------- #
#   Partitioning   #
# ---------------- #
# Create partitions from sfdisk (start,size,type,bootable) in the following order: 
sfdisk $DISK << EOF
,$BOOT_PART_SIZE,U,*
,$SWAP_PART_SIZE,S
;
EOF

mkfs.vfat -F 32 -n Boot $BOOT_PART 	# format boot partition with ext4
mkswap -L Swap $SWAP_PART			# format swap partition
swapon $SWAP_PART					# activate swap

if [ -z ${CRYPTROOT+x} ]; then		# confirm optional system encryption
	cryptsetup luksFormat -M luks2 $ROOT_PART           # encrypt partition with LUKS
	dd if=/dev/random of=/tmp/key bs=512 count=4    	# create random key
	cryptsetup luksAddKey $ROOT_PART /tmp/key           # add key to encrypted partition
	cryptsetup open $ROOT_PART $CRYPTROOT -d /tmp/key   # map decrypted partition to /dev/mapper/crypt_arch

	$ROOT_PART=/dev/mapper/$CRYPTROOT					# set root partition path to mapped cryptroot
fi

mkfs.btrfs -L Arch $ROOT_PART

mount $ROOT_PART /mnt	# mount root partition

# create Btrfs subvolmunes using the suggested filesystem layout for Snapper
# https://wiki.archlinux.org/index.php/Snapper#Suggested_filesystem_layout
btrfs sub create /mnt/@
btrfs sub create /mnt/@home
btrfs sub create /mnt/@pkg
btrfs sub create /mnt/@snapshots

umount /mnt				# unmount root partition
# mount Btrfs root subvolume
mount $ROOT_PART -o subvol=@ /mnt

# create mount points for Btrfs subvolumes
# create mount points for subvolumes
mkdir -p /mnt/.snapshots /mnt/home /mnt/var/cache/pacman/pkg
mount $ROOT_PART -o subvol=@home /mnt/home
mount $ROOT_PART -o subvol=@pkg /mnt/var/cache/pacman/pkg
mount $ROOT_PART -o subvol=@snapshots /mnt/.snapshots

mkdir /mnt/btrfs 	# create mount point for Btrfs partition
mount $ROOT_PART -o subvolid=5 /mnt/btrfs

mkdir /mnt/boot		# create mount point for boot partition
mount $BOOT_PART /mnt/boot


# ---------------- #
#   Installation   #
# ---------------- #
pacstrap /mnt base base-devel btrfs-progs zsh 	# install system base, btrfs tools and a better shell
genfstab -Lp /mnt >> /mnt/etc/fstab 			# generate fstab entries to /mnt/etc/fstab

pacstrap /mnt grub efibootmgr os-prober     	# install boot manager and utility for other OSs
if [ -z ${CRYPTROOT+x} ]; then					# configure grub to recognize encrypted root
	# add "encrypt" to mkinitcpio HOOKS
	hooks=${$(grep HOOKS /mnt/etc/mkinitcpio.conf | tail -1)%)}
	sed -i "s/$hooks/$hooks encrypt/g" /mnt/etc/mkinitcpio.conf
	arch-chroot /mnt mkinitcpio -p linux	# regenerate initramfs

	# mark partition with UUID "device" as encrypted
    uuid=$(blkid -s UUID -o value /dev/sda3)                	# get device uuid for future references
	GRUB_CMDLINE_LINUX="cryptdevice=UUID=$uuid\:$CRYPTROOT"  	# set GRUB_CMDLINE_LINUX variable for grub
	sed -i "s/GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX\"/g" /mnt/etc/default/grub
	sed -i '/GRUB_ENABLE_CRYPTODISK=y/s/^#//' /mnt/etc/default/grub
fi
# generate grub config and install to $boot
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg


# ------------------------ #
#   System configuration   #
# ------------------------ #
loadkeys $KEYMAP 					# set keyboard layout for password input
echo "Set password for root"
arch-chroot /mnt passwd             # set password for root
echo $HOSTNAME > /mnt/etc/hostname  # set hostname

# no idea what @Eiskasten was doing here
# sed -e "s/^\(NAME\s*=\s*\).*$/\1"$HOSTNAME"/" -i /mnt/etc/os-release
# sed -e "s/^\(PRETTY_NAME\s*=\s*\).*$/\1"$HOSTNAME"/" -i /mnt/etc/os-release
# sed -e "s/^\(ANSI_COLOR\s*=\s*\).*$/\1"$COLOR"/" -i /mnt/etc/os-release

# Language and region
echo "LANG=$LANG" > /mnt/etc/locale.conf            # set default keyboard layout
echo "LANGUAGE=$LANGUAGE" >> /mnt/etc/locale.conf   # set languages to use
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf      # set keymap in virtual terminal config

IFS=':' read -rA langs <<< "$language"              # uncomment languages for locale generation
for l in $langs; do; sed -i "s/\#$l\./$l\./g" /mnt/etc/locale.gen; done 
arch-chroot /mnt locale-gen                         # update locale.conf

ln -sf /mnt/usr/share/zoneinfo/$TIMEZONE /mnt/etc/localtime 	# link local time to specified timezone
arch-chroot /mnt systemctl enable systemd-timesyncd     		# enable automatic time settings
arch-chroot /mnt hwclock -w                             		# adjust hardware clock

sed -e "/Color/ s/^#*//" -i /mnt/etc/pacman.conf 			# enable colorful pacman output
sed -e "/TotalDownload/ s/^#*//" -i /mnt/etc/pacman.conf	# enable total download percentage

sed -e "s/^\(MAKEFLAGS\s*=\s*\).*$/\1"-j$((1+$(cat /proc/cpuinfo | grep processor | wc -l)))"/" \
    -i /mnt/etc/makepkg.conf    # add CPU information to makepkg configuration

# install packages set in install.conf
pacstrap /mnt ${PACKAGES[@]}
# enable systemd units set in install.conf
arch-chroot /mnt systemctl enable ${SYSTEMD_UNITS[@]}


# ---------------------- #
#   User configuration   #
# ---------------------- #
# add new user with wheel, audio and video privileges
arch-chroot /mnt useradd -mg users -G wheel,audio,video -s /bin/zsh $USERNAME
arch-chroot /mnt passwd $USERNAME 	# set password for user

# allow members of group wheel to execute any command
cp -v /mnt/etc/sudoers /mnt/etc/sudoers.aui
sed -i '/%wheel ALL=(ALL) ALL/s/^#//' /mnt/etc/sudoers

