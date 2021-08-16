#!/usr/bin/env bash

# Let's set up the steps for automating a crypt setup for lvm on uefi, partitioning with luks!
# we're using parted for creating partitions

################
## VARIABLES
################

HOSTNAME="effie"

DRIVE=/dev/sda

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
#KEYBOARD="us"    # change if you need to
FILESYSTEM=ext4

use_bcm4360(){ return 1; }  # return 0 for "truthy" and 1 for "falsy"

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

crypt_setup(){
    # Get passphrase
    read -p "What is the passphrase?" passph

    echo "$passph" > /tmp/passphrase


    # SETUP ENCRYPTED VOLUME
    cryptsetup -y -v luksFormat "${DRIVE}2" --key-file /tmp/passphrase
    cryptsetup luksOpen  "${DRIVE}2" "$CRYPTVOL"  --key-file /tmp/passphrase
    
    # FILL PART WITH ZEROS
    dd if=/dev/zero of="${DRIVE}2" bs=1M    
    cryptsetup luksClose "${DRIVE}2"                    
    dd if=/dev/urandom of="${DRIVE}2" bs=512 count=20480     
    cryptsetup -v status "${DRIVE}2"    
}

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


## START

part_drive
crypt_setup
prepare_vols
