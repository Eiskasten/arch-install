#!/bin/sh
#
# ============== #
#   Arch Linux   #
# ============== #
#
# Short install guide / script for Arch Linux with LUKS encryption and BTRFS partitions

source install.conf		# load install script configuration


# ---------------- #
#   Partitioning   #
# ---------------- #
# Create partitions from sfdisk (start,size,type,bootable) in the following order:
echo ",$BOOT_PART_SIZE,U,*" >> sfdisk.in    # create boot partition
# only create swap partition without encryption
[ ! -z ${CRYPT_ROOT+x} ] && echo ",$SWAP_PART_SIZE,S" >> sfdisk.in

echo ";" >> sfdisk.in       # create system partition from remaining space
sfdisk $DISK < sfdisk.in    # create partitions using config from sfdisk.in

# confirm optional system encryption
if [ -z ${CRYPT_ROOT+x} ]
then
	cryptsetup luksFormat -M luks2 $ROOT_PART   # encrypt partition with LUKS
	cryptsetup open $ROOT_PART $CRYPT_ROOT -d   # map decrypted partition to crypt root

    pvcreate /dev/mapper/$CRYPT_ROOT            # create LVM physical volume on LUKS encrypted root
    vgcreate vg-system /dev/mapper/$CRYPT_ROOT  # create LVM volume group for the system
    lvcreate -L 16G vg-system -n lv-swap        # create LVM logical volume for swap
    lvcreate -l 100%FREE vg-system -n lv-btrfs  # create LVM logical volume for btrfs

    $SYSTEM_PART=$ROOT_PART                     # save system partition path before overwriting it
    $ROOT_PART=/dev/vg-system/lv-btrfs			# set root partition path to logical volume
    $SWAP_PART=/dev/vg-system/lv-swap           # set swap partition path to logical volume
fi

mkfs.vfat -F 32 -n $BOOT_LABEL $BOOT_PART 	    # format boot partition with ext4

mkswap -L $SWAP_LABEL $SWAP_PART	            # format swap partition
swapon $SWAP_PART				                # activate swap

mkfs.btrfs -L $ROOT_LABEL $ROOT_PART            # format root partition with Btrfs
mount $ROOT_PART /mnt	                        # mount root partition

# create Btrfs subvolumes using the suggested filesystem layout for Snapper
# https://wiki.archlinux.org/index.php/Snapper#Suggested_filesystem_layout
btrfs sub create /mnt/@
btrfs sub create /mnt/@home
btrfs sub create /mnt/@pkg
btrfs sub create /mnt/@snapshots

umount /mnt                         # unmount root partition
mount $ROOT_PART -o subvol=@ /mnt   # mount Btrfs root subvolume

# create mount points for Btrfs subvolumes
mkdir -p {.snapshots,home,var/cache/pacman/pkg}
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
pacstrap /mnt base base-devel btrfs-progs       # install system base and btrfs tools
genfstab -Lp /mnt >> /mnt/etc/fstab 			# generate fstab entries to /mnt/etc/fstab

# add btrfs hook after filesystem hook in mkinitcpio
line=$(grep '^HOOKS' /mnt/etc/mkinitcpio.conf | cut -d : -f 1)s
hooks='btrfs'
# add encrypt lvm2 and resume hooks when using encryption
[ -z ${CRYPT_ROOT+x} ] && hooks="encrypt lvm2 $hooks resume"
# add custom hooks before filesystems hooks in mkinitcpio
sed -i "$line/filesystems/i $hooks" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux            # regenerate initramfs

uuid=$(blkid -s UUID -o value $SYSTEM_PART)     # get system uuid to reference in kernel options
options="root=$ROOT_PART rootflags=subvol=@"    # set root partition and mount options for boot
# add more kernel options for encrypted system including the uuid of the encrypted device
[ -z ${CRYPT_ROOT+x} ] && options="cryptdevice=UUID=$uuid:$CRYPT_ROOT $options resume=$SWAP_PART"

if [ -d '/sys/firmware/efi' ]           # check for UEFI support
then
    pacstrap /mnt efibootmgr     	    # install EFI boot utility
    arch-chroot /mnt bootctl --path=/boot install
    # add boot loader entry configuration
    echo 'title Arch Linux' >> /mnt/boot/loader/entries/arch-linux.conf
    echo 'linux /vmlinuz-linux' >> /mnt/boot/loader/entries/arch-linux.conf
    echo 'initrd /initramfs-linux.img' >> /mnt/boot/loader/entries/arch-linux.conf
    echo "options $options" >> /mnt/boot/loader/entries/arch-linux.conf
    # make arch-linux the default entry
    echo "default arch-linux" > /mnt/boot/loader/loader.conf
else
    pacstrap /mnt grub                  # install grub boot loader
    # set GRUB_CMDLINE_LINUX variable for grub
    sed -i "/GRUB_CMDLINE_LINUX=/a \"$options\"" /mnt/etc/default/grub
    # enable grub cryptodisk support when system is encrypted
    [ -z ${CRYPT_ROOT+x} ] && sed -i '/GRUB_ENABLE_CRYPTODISK=y/s/^#//' /mnt/etc/default/grub
    # generate grub config and install to $boot
    arch-chroot /mnt grub-install --bootloader-id=grub
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi


# ------------------------ #
#   System configuration   #
# ------------------------ #
loadkeys $KEYMAP 					# set keyboard layout for password input
echo "Set password for root"        # inform about root password change dialog
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

# link local time to specified timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
arch-chroot /mnt systemctl enable systemd-timesyncd         # enable automatic time settings
arch-chroot /mnt hwclock -w                             	# adjust hardware clock

sed -e "/Color/ s/^#*//" -i /mnt/etc/pacman.conf 			# enable colorful pacman output
sed -e "/TotalDownload/ s/^#*//" -i /mnt/etc/pacman.conf	# enable total download percentage

sed -e "s/^\(MAKEFLAGS\s*=\s*\).*$/\1"-j$((1+$(cat /proc/cpuinfo | grep processor | wc -l)))"/" \
    -i /mnt/etc/makepkg.conf    # add CPU information to makepkg configuration

# install packages set in install.conf
pacstrap /mnt ${PACKAGES[@]}
# enable systemd units set in install.conf
arch-chroot /mnt systemctl enable ${$SYSTEMD_UNITS[@]}


# ---------------------- #
#   User configuration   #
# ---------------------- #
# add new user with wheel, audio and video privileges
arch-chroot /mnt useradd -mg users -G wheel,audio,video -s $SHELL_PATH $USERNAME
arch-chroot /mnt passwd $USERNAME 	# set password for user

# allow members of group wheel to execute any command
cp -v /mnt/etc/sudoers /mnt/etc/sudoers.aui
sed -i '/%wheel ALL=(ALL) ALL/s/^#//' /mnt/etc/sudoers

