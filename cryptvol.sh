#!/usr/bin/env bash

# Let's set up the steps for automating a crypt setup for lvm on uefi, partitioning with luks!
# we're using parted for creating partitions

################
## VARIABLES
################

HOSTNAME="effie"

DRIVE=/dev/sda
#DRIVE=/dev/nvme0n0

PART_START="537MB"
PART_END="32.2GB"

CRYPTVOL="ArchCrypt"
LV_ROOT="ArchRoot"
LV_SWAP="ArchSwap"
LV_HOME="ArchHome"

ROOTSIZE=13G
SWAPSIZE=4G
HOMESIZE=""

TIME_ZONE="America/New_York"
LOCALE="en_US.UTF-8"
FILESYSTEM=ext4
default_keymap='us'             # set to your keymap name
#KEYBOARD="us"    # change if you need to

use_lvm(){ return 0; }       # return 0 if you want lvm
use_crypt(){ return 0; }     # return 0 if you want crypt 
use_bcm4360(){ return 1; }  # return 0 for "truthy" and 1 for "falsy"
use_nonus_keymap(){ return 1; } # return 0 if using non-US keyboard keymap (default)

# DO WE NEED BROADCOM DRIVERS?
if $(use_bcm4360) ; then
    WIRELESSDRIVERS="broadcom-wl-dkms"
else
    WIRELESSDRIVERS=""
fi

##################
##   SOFTWARE
##################

BASE_SYSTEM=( base base-devel linux linux-headers linux-firmware dkms vim iwd )

devel_stuff=( git nodejs npm npm-check-updates ruby )
printing_stuff=( system-config-printer foomatic-db foomatic-db-engine gutenprint cups cups-pdf cups-filters cups-pk-helper ghostscript gsfonts )
multimedia_stuff=( brasero sox eog shotwell imagemagick sox cmus mpg123 alsa-utils cheese )

##################
##   FUNCTIONS
##################

# VERIFY BOOT MODE
efi_boot_mode(){
    [[ -d /sys/firmware/efi/efivars ]] && return 0
    return 1
}

# All purpose error
error(){ echo "Error: $1" && exit 1; }

# PARTITION DRIVE
part_drive(){
    ## PARTITION DRIVE
    parted -s "$DRIVE" mklabel gpt

    parted -s "$DRIVE" unit mib mkpart primary 1 512 

    #parted -s "$DRIVE" mkpart primary 2 100%
    parted -s "$DRIVE" mkpart primary "$PART_START" 100%

    parted -s "$DRIVE" set 2 lvm on

    # FORMAT EFI PARTITION
    mkfs.vfat -F32 "${DRIVE}1"

    # CHECK PARTITIONS
    fdisk -l "$DRIVE"
    lsblk "$DRIVE"
    read -p "Here're your partitions... Hit enter to continue..." empty
}

# SETUP ENCRYPTION ON VOLUME
crypt_setup(){
    # Get passphrase
    read -p "What is the passphrase?" passph

    echo "$passph" > /tmp/passphrase


    # SETUP ENCRYPTED VOLUME
    cryptsetup -y -v luksFormat "${DRIVE}2" --key-file /tmp/passphrase
    cryptsetup luksOpen  "${DRIVE}2" "$CRYPTVOL"  --key-file /tmp/passphrase
    
    # FILL PART WITH ZEROS
    echo "filling encrypted drive with zeros..."
    dd if=/dev/zero of="${DRIVE}2" bs=1M    
    cryptsetup luksClose "${DRIVE}2"                    
    echo "filling encrypted drive with random bits..."
    dd if=/dev/urandom of="${DRIVE}2" bs=512 count=20480     
    cryptsetup -v status "${DRIVE}2"    
    read -p "Encryption Status: " empty
}

# PREPARE PHYSICAL AND LOGICAL VOLUMES AND MOUNT
prepare_vols(){
    # CREATE PHYSICAL VOL
    pvcreate /dev/mapper/"$CRYPTVOL"

    # CREATE VOLUME GRP and LOGICAL VOLS
    vgcreate "$CRYPTVOL" /dev/mapper/"$CRYPTVOL"

    lvcreate -L "$ROOTSIZE" "$CRYPTVOL" -n "$LV_ROOT"

    lvcreate -L "$SWAPSIZE" "$CRYPTVOL" -n "$LV_SWAP"

    lvcreate -l 100%FREE "$CRYPTVOL" -n "$LV_HOME"


    # FORMAT VOLUMES
    mkfs.ext4 "/dev/${CRYPTVOL}/${LV_ROOT}"
    mkfs.ext4 "/dev/${CRYPTVOL}/${LV_HOME}"
    mkswap "/dev/mapper/${CRYPTVOL}-${LV_SWAP}"
    swapon "/dev/mapper/${CRYPTVOL}-${LV_SWAP}"

    # MOUNT VOLUMES
    mount "/dev/mapper/${CRYPTVOL}-${LV_ROOT}" /mnt
    [[ $? == 0 ]] && mkdir /mnt/home
    mount "/dev/mapper/${CRYPTVOL}-${LV_HOME}" /mnt/home
    mkdir /mnt/boot && mkdir /mnt/boot/efi
    mount "${DRIVE}1" /mnt/boot/efi

    # SHOW OUR WORK
    lsblk
}

# CHECK FOR MIRRORLIST AND INTERNET CONN
check_ready(){
    ### Check of reflector is done
    clear
    echo "Waiting until reflector has finished updating mirrorlist..."
    while true; do
        pgrep -x reflector &>/dev/null || break
        echo -n '.'
        sleep 2
    done

    ### Test internet connection
    clear
    echo "Testing internet connection..."
    $(ping -c 3 archlinux.org &>/dev/null) || (echo "Not Connected to Network!!!" && exit 1)
    echo "Good!  We're connected!!!" && sleep 3

    ## Check time and date before installation
    timedatectl set-ntp true
    echo && echo "Date/Time service Status is . . . "
    timedatectl status
    sleep 4
}

# PART OF LVM INSTALLATION
lvm_hooks(){
    clear
    echo "adding lvm2 to mkinitcpio hooks HOOKS=( base udev ... block lvm2 filesystems )"
    sleep 4
    sed -i 's/^HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)$/HOOKS=(base udev autodetect modconf block lvm2 filesystems keyboard fsck)/g' /mnt/etc/mkinitcpio.conf
    arch-chroot /mnt mkinitcpio -P
    echo "Press any key to continue..."; read empty
}

# INSERT LVM MODULES
lvm_modules(){
    # insert the vol group module
    modprobe dm_mod
    # activate the vol group
    vgchange -ay
}

# INSTALL BASE SYSTEM 
install_base(){
    clear
    echo && echo "Press any key to continue to install BASE SYSTEM..."; read empty
    pacstrap /mnt "${BASE_SYSTEM[@]}"
    echo && echo "Base system installed.  Press any key to continue..."; read empty

    ## UPDATE mkinitrd HOOKS if using LVM
    $(use_lvm) && arch-chroot /mnt pacman -S lvm2
    $(use_lvm) && lvm_hooks
    $(use_lvm) && lvm_modules
}

# GENERATE FSTAB 
gen_fstab(){
    # GENERATE FSTAB
    echo "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    cat /mnt/etc/fstab
    echo && echo "Here's your fstab. Type any key to continue..."; read empty
}

# GENERATE TZ AND LOCALE
gen_tz_locale(){
    ## SET UP TIMEZONE AND LOCALE
    clear
    echo && echo "setting timezone to $TIME_ZONE..."
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$TIME_ZONE" /etc/localtime
    arch-chroot /mnt hwclock --systohc --utc
    arch-chroot /mnt date
    echo && echo "Here's the date info, hit any key to continue..."; read empty

    ## SET UP LOCALE
    clear
    echo && echo "setting locale to $LOCALE ..."
    arch-chroot /mnt sed -i "s/#$LOCALE/$LOCALE/g" /etc/locale.gen
    arch-chroot /mnt locale-gen
    echo "LANG=$LOCALE" > /mnt/etc/locale.conf
    export LANG="$LOCALE"
    cat /mnt/etc/locale.conf
    echo && echo "Here's your /mnt/etc/locale.conf. Type any key to continue."; read empty
}


# GENERATE HOSTNAME CONFIG
do_hostname(){
    ## HOSTNAME
    clear
    echo && echo "Setting hostname..."; sleep 3
    echo "$HOSTNAME" > /mnt/etc/hostname

    cat > /mnt/etc/hosts <<HOSTS
127.0.0.1      localhost
::1            localhost
127.0.1.1      $HOSTNAME.localdomain     $HOSTNAME
HOSTS

    echo && echo "/etc/hostname and /etc/hosts files configured..."
    echo "/etc/hostname . . . "
    cat /mnt/etc/hostname 
    echo "/etc/hosts . . ."
    cat /mnt/etc/hosts
    echo && echo "Here are /etc/hostname and /etc/hosts. Type any key to continue "; read empty
}

# SET ROOT PASSWORD
set_root_pw(){
    ## SET ROOT PASSWD
    clear
    echo "Setting ROOT password..."
    arch-chroot /mnt passwd
}

# MORE INSTALLATION
install_essential(){
    ## INSTALLING MORE ESSENTIALS
    clear
    echo && echo "Enabling dhcpcd, pambase, sshd and NetworkManager services..." && echo
    arch-chroot /mnt pacman -S git openssh networkmanager dhcpcd man-db man-pages pambase
    arch-chroot /mnt systemctl enable dhcpcd.service
    arch-chroot /mnt systemctl enable sshd.service
    arch-chroot /mnt systemctl enable NetworkManager.service
    arch-chroot /mnt systemctl enable systemd-homed
    echo && echo "Press any key to continue..."; read empty
}


# ADD USER ACCT
add_user(){
    clear
    echo && echo "Adding sudo + user acct..."
    sleep 2
    arch-chroot /mnt pacman -S sudo bash-completion sshpass
    arch-chroot /mnt sed -i 's/# %wheel/%wheel/g' /etc/sudoers
    arch-chroot /mnt sed -i 's/%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
    echo && echo "Please provide a username: "; read sudo_user
    echo && echo "Creating $sudo_user and adding $sudo_user to sudoers..."
    arch-chroot /mnt useradd -m -G wheel "$sudo_user"
    echo && echo "Password for $sudo_user?"
    arch-chroot /mnt passwd "$sudo_user"
}

# INSTALL GRUB
install_grub(){
    clear
    echo "Installing grub..." && sleep 4
    arch-chroot /mnt pacman -S grub os-prober

    if $(efi_boot_mode) ; then
        arch-chroot /mnt pacman -S efibootmgr
        
        [[ ! -d /mnt/boot/efi ]] && error "Grub Install: no /mnt/boot/efi directory!!!" 
        arch-chroot /mnt grub-install "$IN_DEVICE" --target=x86_64-efi --bootloader-id=GRUB --efi-directory=/boot/efi

        ## This next bit is for Ryzen systems with weird BIOS/EFI issues; --no-nvram and --removable might help
        [[ $? != 0 ]] && arch-chroot /mnt grub-install \
           "$IN_DEVICE" --target=x86_64-efi --bootloader-id=GRUB \
           --efi-directory=/boot/efi --no-nvram --removable
        echo -e "\n\nefi grub bootloader installed..."
    fi

    echo "Your system is installed.  Type shutdown -h now to shutdown system and remove bootable media, then restart"
    read empty
}



## START INSTALLATION

part_drive
crypt_setup
prepare_vols
check_ready
install_base
gen_fstab
gen_tz_locale
do_hostname
set_root_pw
install_essential
add_user
install_grub
