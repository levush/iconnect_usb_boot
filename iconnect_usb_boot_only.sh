#!/bin/sh

#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#   Iomega iConnect u-Boot USB setup and Arch installer
#   by Igor Slepchin
#
#   Partially based on Dockstar u-Boot mtd0 Installer
#   by Jeff Doozan: http://jeff.doozan.com/debian/uboot/
#   and oxnas installer (http://archlinuxarm.org/os/oxnas/oxnas-install.sh)
#
#   This script will NOT update the stock iConnect u-Boot,
#   which is already capable of booting off USB devices.
#
#   Instead, it will update u-Boot's environment variables
#   to attempt booting off all attached USB devices.
#   After running this script, iConnect will go through
#   all attached USB devices and first try to load
#   the kernel from /boot/uImage on the first
#   partition with root set to /dev/sdX1 (which seems
#   to be the standard setup for plugapps) and then from
#   /uImage with root set to /dev/sdX2 (which seems
#   to be the standard setup after running debian installer).
#
#   If booting from USB does not succeed (e.g., if no 
#   suitable USB drive is attached), you will boot into
#   Iomega's stock kernel.
#
#   Please visit Arch Linux Arm forum if you need help
#   setting up your iConnect:
#   http://archlinuxarm.org/forum/viewtopic.php?f=27&t=1472


LOG_FILE=/var/log/iconnect-install.log

(

set -o pipefail
set -o errexit
set -o errtrace
set -o nounset

trap 'echo "Error, will exit"; exit 1' ERR

FW_SETENV_MD5="25327e90661170a658ab2b39c211a672"
#FW_SETENV_MD5="c9af975c76e1c7b4633eb6f50795a69b"
FW_SETENV=/tmp/fw_setenv
FW_PRINTENV=/tmp/fw_printenv
USB_MOUNT_DIR="/tmp/usb"
PRINTENV_DUMP=/etc/uboot.environment.$(date +%F_%T)
INSTALL_DEVICE=/dev/sda
INSTALL_PARTITION=/dev/sda1
#ARCH_URL_PREFIX=http://archlinuxarm.org/os
ARCH_URL_PREFIX=http://dk.mirror.archlinuxarm.org/os
#ARCH_MD5_FILE=ArchLinuxARM-armv5te-latest.tar.gz.md5
ARCH_MD5_FILE=ArchLinuxARM-kirkwood-latest.tar.gz.md5
ARCH_TAR_FILE=ArchLinuxARM-kirkwood-latest.tar.gz
#if you have problems with ssl ceritificates do this
WGET_OPTS=" -c --no-check-certificate"
#if you have no problems with ssl ceritificates do this
WGET_OPTS=" -c "


NO_UBOOT=0
NO_ARCH=1
NO_MD5=0
USE_EXT3=0
SET_ARC_NUMBER=0
RESET_ARC_NUMBER=0
DRIVE_FORMATTED=0


function usage
{
    echo "Usage: $0 [--no-uboot] [--no-md5] [--set-arcNumber] [--reset-arcNumber]"
    echo "--no-uboot: do not update u-boot's environment."
    echo "--no-md5: do not verify MD5 of downloaded Arch Linux tarball"
    echo "--set-arcNumber: set arcNumber to 2870 to use all iConnect features on Arch"
    echo "--reset-arcNumber: reset arcNumber back to the stock value of 1682"
}

function prompt_yn
{
    while true; do
        echo -n "$1 [Y/n]? "
        read answer
        if [ "x$answer" == "xY" -o "x$answer" == "xy" -o "x$answer" == "xyes" ]
        then
            return 0
        elif [ "x$answer" == "xN" -o "x$answer" == "xn" -o "x$answer" == "xno" ]
        then
            return 1
        fi
    done
}

function stop_iomega_services
{
    # we need to stop Iomega's services
    # or they'll "hog" the mounted devices
    # and won't let us unmount them

    local pid=$(pgrep executord)
    if [ "x$pid" != "x" ]; then

        # first, kill the sshd daemon started by executord,
        # thus orphaning our ssh session.
        # if we don't do that, stopping executord will also close
        # our own ssh session
        pkill -9 -P $pid -f "sshd"

        kill -15 $pid

        local i=60
        while pgrep executord > /dev/null 2>&1 && [ $i -ge 0 ]; do
            echo -n "."
            i=$((i-1))
            sleep 1
        done
        echo

        # restart sshd
        /usr/sbin/sshd

        if pgrep executord > /dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

function check_printenv
{
    # quick sanity check to make sure at least fw_printenv works

    if ! $FW_PRINTENV > /dev/null 2>&1 || $FW_PRINTENV 2>&1 | grep "Bad CRC"; then
        return 1
    elif [ $($FW_PRINTENV | wc -l) -eq 0 ]; then
        return 1
    else
        return 0
    fi
}

function check_system
{
    # Try to check if we're running a stock Iomega iConnect kernel

    if ! uname -a | grep "armv5tel GNU/Linux" > /dev/null ; then
        # uname check isn't very useful given that there are now
        # two upgrades out and I don't have uname -a info
        # for any but the latest one.
        return 1
    fi

    if [ ! -e /etc/debian_version ] ; then
        # Well, this'll be there if you're running debian
        # but will at least catch other distros
        return 1
    fi

    if [ ! -e /mnt/apps ] || [ ! -e /oem ] ; then
        # These are cramfs mounted on the stock iConnect
        return 1
    fi

    return 0
}

function unpack_fw_setprintenv
{
    if ! grep '^FW_SETENV_BINARY:$' $0 > /dev/null ; then
        return 1
    fi

    lineno=$(grep -n '^FW_SETENV_BINARY:$' $0 | cut -d: -f 1)
    lineno=$(($lineno+1))

    if ! tail -n +${lineno} $0 | base64 -d > $FW_PRINTENV ; then
        return 1
    fi

    local md5=$(md5sum $FW_PRINTENV | cut -d' ' -f 1)
    if [ $md5 != $FW_SETENV_MD5 ]; then
        return 1
    fi

    chmod +x $FW_PRINTENV

    if [ -e $FW_SETENV ]; then
        rm $FW_SETENV
    fi

    if ! ln -s $FW_PRINTENV $FW_SETENV; then
        return 1
    fi

    return 0
}

function dump_uboot_environment
{
    $FW_PRINTENV > $PRINTENV_DUMP 2>&1
}

function setenv
{
    local name=$1
    local value=$2

    echo "$name=$value"
    $FW_SETENV $name $value
}

function setup_usb_boot
{
    setenv usb_scan_1 'setenv usb 0:1; setenv dev sda1'
    setenv usb_scan_2 'setenv usb 1:1; setenv dev sdb1'
    setenv usb_scan_3 'setenv usb 2:1; setenv dev sdc1'
    setenv usb_scan_4 'setenv usb 3:1; setenv dev sdd1'
    setenv usb_scan_5 'setenv usb 0:1; setenv dev sda2'
    setenv usb_scan_6 'setenv usb 1:1; setenv dev sdb2'
    setenv usb_scan_7 'setenv usb 2:1; setenv dev sdc2'
    setenv usb_scan_8 'setenv usb 3:1; setenv dev sdd2'

    setenv bootcmd_usb_1 'run usb_scan_1;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /boot/uImage;bootm 0x00800000'
    setenv bootcmd_usb_2 'run usb_scan_2;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /boot/uImage;bootm 0x00800000'
    setenv bootcmd_usb_3 'run usb_scan_3;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /boot/uImage;bootm 0x00800000'
    setenv bootcmd_usb_4 'run usb_scan_4;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /boot/uImage;bootm 0x00800000'
    setenv bootcmd_usb_5 'run usb_scan_5;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /uImage;bootm 0x00800000'
    setenv bootcmd_usb_6 'run usb_scan_6;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /uImage;bootm 0x00800000'
    setenv bootcmd_usb_7 'run usb_scan_7;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /uImage;bootm 0x00800000'
    setenv bootcmd_usb_8 'run usb_scan_8;run make_usb_bootargs;ext2load usb $(usb) 0x00800000 /uImage;bootm 0x00800000'

    setenv make_usb_bootargs 'run make_boot_args;setenv bootargs $(bootargs) root=/dev/$(dev) rootdelay=10'

    setenv bootcmd_usb 'usb start;run bootcmd_usb_1;run bootcmd_usb_2;run bootcmd_usb_3;run bootcmd_usb_4;run bootcmd_usb_5;run bootcmd_usb_6;run bootcmd_usb_7;run bootcmd_usb_8'

    setenv bootcmd 'run bootcmd_usb; run flash_load'
}

function check_usb_devices
{
    usb_devices_num=$(lsusb | wc -l)
    if [ "x$usb_devices_num" != "x3" ]; then
        return 1
    else
        return 0
    fi
}

function prepare_usb_storage
{
    for i in `seq 1 100`; do
        while umount ${INSTALL_DEVICE}$i > /dev/null 2>&1; do true; done
    done

    if prompt_yn "Would you like to reformat the attached USB device (all data will be lost)"; then
        echo "Creating partition..."
        sfdisk $INSTALL_DEVICE <<EOF
,,83,
EOF
        echo "Creating partition - done."
        echo
        echo "Creating file system. This may take a few minutes..."
        mke2fs $INSTALL_PARTITION
        DRIVE_FORMATTED=1
        echo "Creating file system - done."
        echo
    else
        echo "The data on the attached device may be overwritten."
        if ! prompt_yn "Would you like to proceed"; then
            return 1
        fi
    fi

    return 0
}

function get_arch_md5
{
    echo "Getting Arch Linux md5..."
    local CUR_DIR=`pwd`

    cd /tmp
    rm -f $ARCH_MD5_FILE
    wget $WGET_OPTS $ARCH_URL_PREFIX/$ARCH_MD5_FILE
    ARCHLINUXARM_MD5=$(cat $ARCH_MD5_FILE | cut -d' ' -f 1)
    cd $CUR_DIR

    echo "Expected Arch Linux md5 is $ARCHLINUXARM_MD5"
    echo

    return 0
}

function download_and_install_arch
{
    echo "Downloading Arch Linux image..."
    local CUR_DIR=`pwd`

    if [ $NO_MD5 -ne 1 ]; then
        if ! get_arch_md5; then
            return 1
        fi
    fi

    cd $USB_MOUNT_DIR
    rm -f $USB_MOUNT_DIR/$ARCH_TAR_FILE
    wget $WGET_OPTS --progress=dot:mega $ARCH_URL_PREFIX/$ARCH_TAR_FILE
    cd $CUR_DIR

    if [ ! -f $USB_MOUNT_DIR/$ARCH_TAR_FILE ]; then
        echo "Could not download Arch Linux tarball"
        return 1
    fi

    if [ $NO_MD5 -ne 1 ]; then
        local md5=$(md5sum $USB_MOUNT_DIR/$ARCH_TAR_FILE | cut -d' ' -f 1)
        if [ "x$md5" != "x$ARCHLINUXARM_MD5" ]; then
            echo "Arch Linux download checksum mismatch (download is corrupted?)"
            echo "Please try running the script again."
            return 1
        else
            echo "MD5 is correct"
        fi
    fi
    echo "Downloading Arch Linux image - done."
    echo

    echo "Copying Arch Linux to USB storage. This will take a few minutes..."
    tar -C $USB_MOUNT_DIR --overwrite --checkpoint=3000 -zxf $USB_MOUNT_DIR/$ARCH_TAR_FILE
    rm $USB_MOUNT_DIR/$ARCH_TAR_FILE
    sync
    echo "Copying Arch Linux to USB storage - done."
    echo

    return 0
}

function tweak_arch
{
    echo "# iomega iconnect
# MTD device name       Device offset   Env. size       Flash sector size
/dev/mtd0               0xa0000         0x20000         0x20000" > $USB_MOUNT_DIR/etc/fw_env.config
}

function maybe_add_journal
{
    if [ $DRIVE_FORMATTED -eq 1 ] && [ $USE_EXT3 -eq 1 ]; then
        echo "Converting ext2 to ext3..."
        tune2fs -j $INSTALL_PARTITION
        sync
    fi
}

function set_arc_number
{
    local arc_number=$1
    local message=$2

    CURRENT_ARC=$($FW_PRINTENV arcNumber)
    if [ "x$CURRENT_ARC" != "xarcNumber=$arc_number" ]; then

        if [[ "x$arc_number" == "x1682" &&
                "x$CURRENT_ARC" != "xarcNumber=2870" ]] ||
            [[ "x$arc_number" == "x2870" &&
                "x$CURRENT_ARC" != "xarcNumber=1682" ]]
        then
            echo "This does not look like iConnect. Exiting..."
            return 1
        fi

        echo "$message"

        if prompt_yn "Would you like to proceed"; then
            $FW_SETENV arcNumber $arc_number
            CURRENT_ARC=$($FW_PRINTENV arcNumber)
            if [ "x$CURRENT_ARC" == "xarcNumber=$arc_number" ]; then
                echo "arcNumber set to $arc_number."
            else
                echo
                echo "Error! arcNumber could not be set: $CURRENT_ARC"
                return 1
            fi
        fi
    else
        echo
        echo "arcNumber is already set to $arc_number."
    fi

    return 0
}


# parse command line
for i in $*
do
    case $i in
        --no-uboot)
            NO_UBOOT=1
            ;;
#        --no-arch)
#            NO_ARCH=1
#            ;;
        --no-md5)
            NO_MD5=1
            ;;
        --ext3)
            USE_EXT3=1
            ;;
        --set-arcNumber)
            SET_ARC_NUMBER=1
            ;;
        --reset-arcNumber)
            RESET_ARC_NUMBER=1
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ x`id -u` != "x0" ]; then
    echo "This script must be run under root account."
    exit 1
fi

echo
echo "The output of this run will be saved to $LOG_FILE."
echo "$LOG_FILE is not preserved across reboots;"
echo "please save it if anything goes wrong and you need help."
echo

if [ $SET_ARC_NUMBER -eq 1 ] && [ $RESET_ARC_NUMBER -eq 1 ]; then
    echo "Only one of --set-arcNumber or --reset-arcNumber can be used"
    exit 1
fi

if [ $NO_ARCH -eq 1 ] && [ $NO_UBOOT -eq 1 ] &&
    [ $SET_ARC_NUMBER -eq 0 ] && [ $RESET_ARC_NUMBER -eq 0 ]; then
    echo "Nothing to do, exiting."
    exit 0
fi

if [ $NO_UBOOT -ne 1 ] ||
    [ $SET_ARC_NUMBER -eq 1 ] || [ $RESET_ARC_NUMBER -eq 1 ]; then
    if ! unpack_fw_setprintenv ; then
        echo "Could not unpack fw_setenv binary. Exiting..."
        exit 1
    fi

    if ! check_printenv ; then
        echo "Included fw_setenv is not operational. Exiting..."
        exit 1
    fi
fi

if [ $NO_UBOOT -ne 1 ]; then
    if prompt_yn "Would you like to update your iConnect's boot sequence"
    then
        if ! check_system ; then
            echo "This does not look like a stock Iomega iConnect. Exiting..."
            exit 1
        fi

        echo
        echo "Your old uboot environment will be saved to $PRINTENV_DUMP"
        echo

        dump_uboot_environment
        setup_usb_boot

        echo
        echo "Your u-boot environment has been successfully updated."
        echo
        echo "If everything worked as it was supposed to,"
        echo "your iConnect will now be able to boot from an attached"
        echo "USB storage device if available and will fall back"
        echo "to booting to the original Iomega kernel if not."
        echo
    fi
fi


if [ $NO_ARCH -ne 1 ]; then
    if ! prompt_yn "Would you like to install Arch Linux on the attached USB storage device"; then
        exit 0
    fi

    sync

    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Please disconnect ALL USB devices and (re-)connect"
    echo "the one you want to use for the installation."
    echo "Press Enter when ready."
    read

    if ! check_usb_devices; then
        echo "Exactly one USB storage device must be attached to iConnect"
        echo "to proceed with the installation."
        echo "Please re-run this script when that condition is met."
        exit 1
    fi

    echo "Stopping Iomega's services..."
    if ! stop_iomega_services; then
        echo "Could not stop Iomega services."
        echo "Try running \"killall -15 executord\" from command line"
        echo "and then re-running this script."
        exit 1
    fi
    echo "Stopping Iomega's services - done."
    echo

    if ! prepare_usb_storage; then
        exit 1
    fi

    if [ ! -e $USB_MOUNT_DIR ]; then
        mkdir $USB_MOUNT_DIR
    fi

    mount $INSTALL_PARTITION $USB_MOUNT_DIR
    fstype=$(mount | grep "$INSTALL_PARTITION" | sed s'/.* \(.*\) (.*)/\1/')
    if [ "$fstype" != "ext2" -a "$fstype" != "ext3" ]; then
        echo "Found $fstype filesystem on $INSTALL_PARTITION."
        echo "Only ext2 and ext3 can be used for boot partition."
        echo "Please either insert a properly formatted USB storage device"
        echo "or re-run this script and let it partition one for you."
        exit 1
    fi

    download_and_install_arch
    if [ $? -ne 0 ]; then
        exit 1
    fi

    tweak_arch
    sync
    umount $INSTALL_PARTITION
    maybe_add_journal
fi

if [ $SET_ARC_NUMBER -eq 1 ]; then
    message="!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!
You chose to set the arcNumber to 2870.
Doing so will make it impossible to boot Iomega's stock kernel
but will provide better support for iConnect-specific features
(LED control, proper eth0 initialization, temperature sensor)
when booting Arch (and possibly Debian) kernels.

You will be able to reset the arcNumber back to the shipped default
by using the iConnect arcNumber rescue disk available at
Arch Linux Arm support forum:
http://archlinuxarm.org/forum/viewforum.php?f=27&sid=b1a8a251a02ba336c44a6c2974ec79f6
"
    set_arc_number 2870 "$message"
fi

if [ $RESET_ARC_NUMBER -eq 1 ]; then
    message="You chose to set the arcNumber to 1682.
Doing so will make it possible to boot Iomega's stock kernel
but will disable support of iConnect-specific features
(LEDs control, proper eth0 initialization, temperature sensor)
when booting Arch and Debian kernels.
"
    set_arc_number 1682 "$message"
fi


echo
echo "Setup successful, you can reboot now."

) 2>&1 | tee -a $LOG_FILE

exit 0

# Below is a base64-encoded fw_setenv binary
# that is known to work on the stock iConnect.
# DO NOT ADD OR CHANGE ANYTHING AFTER THIS LINE
FW_SETENV_BINARY:
f0VMRgEBAQAAAAAAAAAAAAIAKAABAAAAUIcAADQAAACgQQAAAgAABTQAIAAIACgAIgAfAAEAAHAw
OQAAMLkAADC5AAAIAAAACAAAAAQAAAAEAAAABgAAADQAAAA0gAAANIAAAAABAAAAAQAABQAAAAQA
AAADAAAANAEAADSBAAA0gQAAEwAAABMAAAAEAAAAAQAAAAEAAAAAAAAAAIAAAACAAAA8OQAAPDkA
AAUAAAAAgAAAAQAAADw5AAA8OQEAPDkBACgCAACkAgAABgAAAACAAAACAAAASDkAAEg5AQBIOQEA
6AAAAOgAAAAGAAAABAAAAAQAAABIAQAASIEAAEiBAAAgAAAAIAAAAAQAAAAEAAAAUeV0ZAAAAAAA
AAAAAAAAAAAAAAAAAAAABgAAAAQAAAAvbGliL2xkLWxpbnV4LnNvLjMAAAQAAAAQAAAAAQAAAEdO
VQAAAAAAAgAAAAYAAAAOAAAAEQAAABwAAAAaAAAAAAAAABYAAAAQAAAAGwAAAAAAAAAZAAAACwAA
AA8AAAAJAAAAEwAAABUAAAAYAAAAAAAAABIAAAAXAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
AAAAAAAAAAAAAAAABwAAAAAAAAACAAAABQAAAAMAAAAAAAAABAAAAAAAAAAIAAAADAAAAAAAAAAR
AAAADgAAAAAAAAAAAAAABgAAAAoAAAAAAAAADQAAABQAAAAAAAAAAAAAAAAAAAAAAAAAlwAAACSG
AABkAAAAEgAAAKsAAAAwhgAA1AAAABIAAAAyAAAAPIYAAOgDAAASAAAAywAAAEiGAAC4AAAAEgAA
ALQAAABUhgAAUAIAABIAAAABAAAAAAAAAAAAAAAgAAAAOAAAAGyGAACcBQAAEgAAACMAAAB4hgAA
UAAAABIAAAArAAAAhIYAAMAAAAASAAAAxgAAAJCGAADQAQAAEgAAAFcAAACchgAAZAAAABIAAACL
AAAAqIYAAGQAAAASAAAAhAAAALSGAAAcAAAAEgAAAD8AAADAhgAAYAAAABIAAABvAAAAzIYAAJwC
AAASAAAAkQAAANiGAABkAAAAEgAAAIoAAADkhgAAtAIAABIAAACcAAAA8IYAACwAAAASAAAAdgAA
APyGAADcAwAAEgAAAGQAAAAIhwAA5AIAABIAAABcAAAAaDsBAAQAAAARABcAfQAAAHA7AQAEAAAA
EQAXAGkAAAAUhwAAHAAAABIAAAAaAAAAIIcAAMQBAAASAAAApAAAACyHAAA0AAAAEgAAAEYAAAA4
hwAAHAAAABIAAABjAAAARIcAAJACAAASAAAAAF9fZ21vbl9zdGFydF9fAGxpYmMuc28uNgBfSU9f
cHV0YwBzdHJyY2hyAHBlcnJvcgBhYm9ydABjYWxsb2MAc3RybGVuAF9fZXJybm9fbG9jYXRpb24A
cmVhZABzdGRvdXQAZnB1dHMAbHNlZWsAbWVtY3B5AG1hbGxvYwBzdGRlcnIAaW9jdGwAZndyaXRl
AGNsb3NlAG9wZW4AZnByaW50ZgBzdHJjbXAAc3RyZXJyb3IAX19saWJjX3N0YXJ0X21haW4AZnJl
ZQBfX3hzdGF0AEdMSUJDXzIuNAAAAAACAAIAAgACAAIAAAACAAIAAgACAAIAAgACAAIAAgACAAIA
AgACAAIAAgACAAIAAgACAAIAAgAAAAEAAQAQAAAAEAAAAAAAAAAUaWkNAAACANMAAAAAAAAAoDoB
ABUGAABoOwEAFBUAAHA7AQAUFgAAPDoBABYBAABAOgEAFgIAAEQ6AQAWAwAASDoBABYEAABMOgEA
FgUAAFA6AQAWBgAAVDoBABYHAABYOgEAFggAAFw6AQAWCQAAYDoBABYKAABkOgEAFgsAAGg6AQAW
DAAAbDoBABYNAABwOgEAFg4AAHQ6AQAWDwAAeDoBABYQAAB8OgEAFhEAAIA6AQAWEgAAhDoBABYT
AACIOgEAFhQAAIw6AQAWFwAAkDoBABYYAACUOgEAFhkAAJg6AQAWGgAAnDoBABYbAAANwKDhANgt
6QSwTOJeAADrAKid6ATgLeUE4J/lDuCP4AjwvuUQtAAAAMaP4gvKjOIQ9LzlAMaP4gvKjOII9Lzl
AMaP4gvKjOIA9LzlAMaP4gvKjOL487zlAMaP4gvKjOLw87zlAMaP4gvKjOLo87zlAMaP4gvKjOLg
87zlAMaP4gvKjOLY87zlAMaP4gvKjOLQ87zlAMaP4gvKjOLI87zlAMaP4gvKjOLA87zlAMaP4gvK
jOK487zlAMaP4gvKjOKw87zlAMaP4gvKjOKo87zlAMaP4gvKjOKg87zlAMaP4gvKjOKY87zlAMaP
4gvKjOKQ87zlAMaP4gvKjOKI87zlAMaP4gvKjOKA87zlAMaP4gvKjOJ487zlAMaP4gvKjOJw87zl
AMaP4gvKjOJo87zlAMaP4gvKjOJg87zlAMaP4gvKjOJY87zlAMaP4gvKjOJQ87zlJMCf5QCwoOME
EJ3kDSCg4QQgLeUEAC3lEACf5RAwn+UEwC3ltv//66///+u0sAAAlK8AALiwAAANwKDhANgt6QSw
TOIYMJ/lAzCP4BQgn+UCMJPnAABT4wAAAAqr///rAKid6JCyAABwAAAAFCCf5QAw0uUAAFPjAQAA
GgEwg+IAMMLlHv8v4XQ7AQAoAJ/lDcCg4QDYLekEsEziADCQ5QAAU+MDAAAKEDCf5QAAU+MAAAAK
M/8v4QConehEOQEAAAAAAA3AoOEA2C3pBLBM4hDQTeIQAAvlFBAL5RggC+UQMBvlAzDg4RAwC+V6
AADqFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPiTDKf5QIhk+cQMBvlIzSg4QMwIuAQMAvlFDAb5QEw
g+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPiEDKf5QIhk+cQMBvlIzSg4QMwIuAQMAvlFDAb
5QEwg+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPi1DGf5QIhk+cQMBvlIzSg4QMwIuAQMAvl
FDAb5QEwg+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPimDGf5QIhk+cQMBvlIzSg4QMwIuAQ
MAvlFDAb5QEwg+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPiXDGf5QIhk+cQMBvlIzSg4QMw
IuAQMAvlFDAb5QEwg+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPiIDGf5QIhk+cQMBvlIzSg
4QMwIuAQMAvlFDAb5QEwg+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPi5DCf5QIhk+cQMBvl
IzSg4QMwIuAQMAvlFDAb5QEwg+IUMAvlFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPiqDCf5QIhk+cQ
MBvlIzSg4QMwIuAQMAvlFDAb5QEwg+IUMAvlGDAb5QgwQ+IYMAvlGDAb5QcAU+OB//+KGDAb5QAA
U+MUAAAKFDAb5QAw0+UDIKDhEDAb5QMwIuD/IAPiSDCf5QIhk+cQMBvlIzSg4QMwIuAQMAvlFDAb
5QEwg+IUMAvlGDAb5QEwQ+IYMAvlGDAb5QAAU+Pq//8aEDAb5QMw4OEDAKDhDNBL4gConehgsQAA
DcCg4RDYLekEsEziHNBN4igAC+X9BgDrADCg4QAAU+MCAAAKADCg4ywwC+UyAADq1DCf5Qwwk+Ug
MAvlKAAA6iAwG+UcMAvlEwAA6rgwn+UMQJPlLwAA6wAwoOEDIITgHDAb5QMAUuEIAACKnDCf5QAw
k+WYAJ/lARCg4yUgoOPr/v/rADCg4ywwC+UaAADqHDAb5QEwg+IcMAvlHDAb5QAw0+UAAFPj5///
GigAG+UgEBvlmQYA6wAwoOEYMAvlGDAb5QAAU+MCAAAKGDAb5SwwC+UIAADqHDAb5QEwg+IgMAvl
IDAb5QAw0+UAAFPj0v//GgAwoOMsMAvlLDAb5QMAoOEQ0EviEKid6MA7AQBwOwEAYLUAAA3AoOEA
2C3pBLBM4gjQTeJUMJ/lADCT5VAQn+UUAKDjAzGg4YMhoOECMIPgATCD4AAwg+AAMJPlBDBD4hAw
C+UsMJ/lADCT5QAAU+MCAAAKEDAb5QEwQ+IQMAvlEDAb5QMAoOEM0EviAKid6Nw7AQB4OwEA1DsB
AA3AoOEQ2C3pBLBM4jTQTeI4AAvlPBAL5QAwoOMgMAvllgYA6wAwoOEAAFPjAgAACgAw4ONAMAvl
qgAA6jgwG+UBAFPjKgAAGqgyn+UMMJPlMDAL5R8AAOowMBvlLDAL5RMAAOqMMp/lDECT5cX//+sA
MKDhAyCE4CwwG+UDAFLhCAAAinAyn+UAMJPlbAKf5QEQoOMlIKDjgf7/6wAw4ONAMAvljwAA6iww
G+UBMIPiLDAL5SwwG+UAMNPlAABT4+f//xowABvlfv7/6ywwG+UBMIPiMDAL5TAwG+UAMNPlAABT
49v//xoAMKDjQDAL5XwAAOo8MBvlBDCD4gAwk+UDAKDh+BGf5Xf+/+sAMKDhAABT4xMAABoBMKDj
JDAL5TwwG+UEMIPiPDAL5TgwG+UBMEPiODAL5TgwG+UCAFPjCgAACrAxn+UAMJPltAGf5QEQoOM0
IKDjUf7/6wAw4ONAMAvlXwAA6gAwoOMkMAvlATCg4ygwC+VUAADqKDAb5QMxoOEDIKDhPDAb5QMw
guAAMJPlHDAL5QAwoOMYMAvlUDGf5Qwwk+UwMAvlNQAA6jAwG+UsMAvlEwAA6jQxn+UMQJPlb///
6wAwoOEDIITgLDAb5QMAUuEIAACKGDGf5QAwk+UUAZ/lARCg4yUgoOMr/v/rADDg40AwC+U5AADq
LDAb5QEwg+IsMAvlLDAb5QAw0+UAAFPj5///GhwAG+UwEBvl2QUA6wAwoOEYMAvlGDAb5QAAU+MP
AAAKJDAb5QAAU+MJAAAavDCf5QAwk+UcABvlAxCg4Sn+/+uoMJ/lADCT5T0AoOMDEKDhG/7/6xgA
G+UT/v/rBgAA6iwwG+UBMIPiMDAL5TAwG+UAMNPlAABT48X//xoYMBvlAABT4wcAABpQMJ/lADCT
5QMAoOFYEJ/lHCAb5fz9/+sAMODjIDAL5SgwG+UBMIPiKDAL5SggG+U4MBvlAwBS4ab//7ogMBvl
QDAL5UAwG+UDAKDhENBL4hConejAOwEAcDsBAGC1AACItQAAjLUAAGg7AQDEtQAADcCg4TDYLekE
sEziQNBN4jgAC+U8EAvlADCg4yAwC+U4MBvlAQBT4wYAAMrs/f/rACCg4RYwoOMAMILlABDg40QQ
C+U1AQDqxwUA6wAwoOEAAFPjAgAACgAg4ONEIAvlLgEA6jwwG+UEMIPiADCT5RwwC+W0NJ/lDDCT
5SgwC+UoMBvlJDAL5SkAAOooMBvlJDAL5RcAAOqQNJ/lDECT5fP+/+sAMKDhAyCE4CQwG+UDAFLh
DAAAinQ0n+UAMJPlcASf5QEQoOMlIKDjr/3/68P9/+sAIKDhFjCg4wAwguUAMODjRDAL5QwBAOok
MBvlATCD4iQwC+UkMBvlADDT5QAAU+Pj//8aHAAb5SgQG+VZBQDrADCg4SAwC+UgMBvlAABT4wYA
ABokMBvlATCD4igwC+UoMBvlADDT5QAAU+PR//8aIDAb5QAAU+M8AAAKHAAb5eATn+We/f/rADCg
4QAAU+MFAAAKHAAb5cwTn+WY/f/rADCg4QAAU+MMAAAarDOf5QAwk+UDAKDhsBOf5RwgG+WA/f/r
kf3/6wAgoOEeMKDjADCC5QAQ4ONEEAvl2gAA6iQwG+UBMIPiJDAL5SQwG+UAMNPlAABT4wMAABoo
MBvlACCg4wAgw+USAADqJDAb5QAw0+UoIBvlADDC5SQwG+UBMIPiJDAL5SgwG+UAMNPlAABT4wMA
ABokMBvlADDT5QAAU+MDAAAKKDAb5QEwg+IoMAvl7P//6igwG+UBMIPiKDAL5SggG+UAMKDjADDC
5TgwG+UCAFPjlgAA2tgyn+UMMJPlKDAL5QIAAOooMBvlATCD4igwC+UoMBvlADDT5QAAU+P4//8a
KDAb5QEwg+IAMNPlAABT4/P//xqYMp/lDCCT5SgwG+UDAFLhAgAAKigwG+UBMIPiKDAL5RwAG+Us
/f/rADCg4QIwg+IsMAvlAjCg4zAwC+UPAADqMDAb5QMxoOEDIKDhPDAb5QMwguAAMJPlAwCg4R79
/+sAIKDhLDAb5QMwguABMIPiLDAL5TAwG+UBMIPiMDAL5TAgG+U4MBvlAwBS4ev//7oIMp/lDECT
5VH+/+sAMKDhAzCE4AMgoOEoMBvlAiBj4CwwG+UDAFLhCwAAquAxn+UAMJPlAwCg4egRn+UcIBvl
Df3/6wAg4ONEIAvlawAA6igwG+UBMIPiKDAL5RwwG+UAMNPlKCAb5QAwwuUoMBvlACDT5QAwoONM
MEvlAABS4wEAAAoBMKDjTDBL5UwQW+X/MAHiHCAb5QEgguIcIAvlAABT4+n//xoCMKDjMDAL5SsA
AOowMBvlAzGg4QMgoOE8MBvlAzCC4AAwk+UYMAvlMDAb5QIAU+MCAAAaPSCg40AgC+UBAADqIDCg
40AwC+UoIBvlQBAb5QEwoOEAMMLlKDAb5QEwg+IoMAvlGDAb5QAw0+UoIBvlADDC5SgwG+UAINPl
ADCg41QwS+UAAFLjAQAACgEwoONUMEvlVCBb5f8wAuIYIBvlASCC4hggC+UAAFPj6f//GjAwG+UB
MIPiMDAL5TAgG+U4MBvlAwBS4c///7ooMBvlATCD4igwC+UoIBvlADCg4wAwwuV8MJ/lBFCT5XQw
n+UMMJPlA0Cg4ev9/+sAMKDhAACg4wQQoOEDIKDh+fz/6wAwoOEAMIXlAgCg47QDAOsAMKDhAABT
4wgAAAo4MJ/lADCT5UgAn+UBEKDjIyCg46D8/+sAMODjRDAL5QEAAOoAEKDjRBAL5UQwG+UDAKDh
FNBL4jConejAOwEAcDsBAGC1AADgtQAA6LUAAPC1AAAItgAANLYAAA3AoOEA2C3pBLBM4hjQTeIY
AAvlATCg4SAgC+UZMEvlGTBb5QQAU+MTAAAaGAAb5VwQn+UgIBvldPz/6wAwoOEQMAvlEDAb5QAA
U+MEAACqQACf5WH8/+sQMBvlJDAL5QcAAOoQMBvlAABT4wIAAAoQMBvlJDAL5QEAAOoAMKDjJDAL
5SQwG+UDAKDhDNBL4gConegLTQhAWLYAAA3AoOFw2C3pBLBM4lzQTeJIAAvlTBAL5VAgC+VUMAvl
ADCg4zAwC+VUMBvlLDAL5UgwG+WME5/lGACg4wMxoOGDIaDhAjCD4AEwg+AAMIPgADCT5QAgY+IE
MJvlAzAC4ABAoOM8MAvlOEAL5QQgm+U8MEviGACT6AIwY+AkMAvlCDDb5QQAU+MtAAAaSDAb5TAT
n+UYAKDjAzGg4YMhoOECMIPgATCD4AAwg+AAMJPlNDAL5UgwG+UIE5/lEACg4wMxoOGDIaDhAjCD
4AEwg+AAMIPgACCT5TQwG+UAMGPiA8AC4EgwG+XYEp/lHACg4wMxoOGDIaDhAjCD4AEwg+AAMIPg
ACCT5TQwG+WSAwPgAzCM4CgwC+UkIBvlNDAb5QMgYuAsMBvlAwBS4ZsAACokMBvlNCAb5QIwY+As
MAvllgAA6gAwoOM0MAvlBCCb5VQwG+UDMILgKDAL5Y8AAOoIMNvlPCBL4kwAG+UDEKDhe///6wAw
oOEgMAvlIDAb5QAAU+MCAACqABDg43AQC+WIAADqJDAb5QMQoOHBL6DhPDBL4hgAk+gDEJHgBCCi
4CwwG+UAQKDjAVCg4QJgoOEDUJXgBGCm4GxQC+VoYAvlKDAb5QMQoOHBL6DhZBAL5WAgC+VoIBvl
YDAb5QMAUuEIAADKaFAb5WBgG+UGAFXhDQAAGmwQG+VkIBvlAgBR4QAAAIoIAADqrDGf5QAwk+Wo
AZ/lARCg4yEgoOPc+//rADDg43AwC+VeAADqIDAb5QAAU+MJAAAKNDAb5QMQoOEAIKDjPDBL4hgA
k+gBMJPgAkCk4DwwC+U4QAvlSwAA6jwwS+IYAJPoAyCg4SQwG+UDMILgTAAb5QMQoOEAIKDjz/v/
6zAgG+VQMBvlAzCC4EwAG+UDEKDhLCAb5ar7/+sAMKDhIDAL5SAgG+UsMBvlAwBS4RQAAAr8MJ/l
AFCT5UgwG+UDMaDhgyGg4QIwg+DgIJ/lAkCD4ML7/+sAMKDhADCT5QMAoOF8+//rADCg4QUAoOHI
EJ/lBCCg4af7/+sAUODjcFAL5SYAAOowIBvlLDAb5QMwguAwMAvlNDAb5UAwC+VUIBvlMDAb5QIw
Y+BEMAvlRDAb5UBgG+VYYAvlXDAL5VwQG+VYIBvlAgBR4QEAAJpYMBvlXDAL5VxQG+UsUAvlADCg
4yQwC+U0MBvlAxCg4QAgoOM8MEviGACT6AEwk+ACQKTgPDAL5ThAC+UwIBvlVDAb5QMAUuFr//86
MGAb5XBgC+VwMBvlAwCg4RjQS+JwqJ3oeDsBAHA7AQB0tgAAmLYAAA3AoOFw2C3pBLBM4mzQTeJY
AAvlXBAL5WAgC+VkMAvlADCg4zQwC+VYMBvlFBWf5RgAoOMDMaDhgyGg4QIwg+ABMIPgADCD4AAw
k+VAMAvlWDAb5ewUn+UQAKDjAzGg4YMhoOECMIPgATCD4AAwg+AAIJPlQDAb5QAwY+IDwALgWDAb
5bwUn+UcAKDjAzGg4YMhoOECMIPgATCD4AAwg+AAIJPlQDAb5ZIDA+ADMIzgJDAL5UAwG+UAIGPi
BDCb5QMwAuAsMAvlJCAb5SwwG+UCMGPgPDAL5SwwG+XDT6DhVDAL5VBAC+UEIJvlLDAb5QIwY+Ao
MAvlKCAb5WQwG+UDIILgQDAb5QMwguABIEPiQDAb5QAwY+IDMALgMDAL5TAgG+VkMBvlAwBS4TAA
AJo8ABvlKvv/6wAwoOFEMAvlRDAb5QAAU+MOAAAa+DOf5QBAk+Ux+//rADCg4QAwk+UDAKDh6/r/
6wAwoOEEAKDh2BOf5TwgG+UW+//rABDg43gQC+XrAADqLDAb5QAwjeUIMNvlBDCN5VgAG+VcEBvl
RCAb5TAwG+We/v/rADCg4SAwC+UgIBvlMDAb5QMAUuECAAAKACDg43ggC+XZAADqKDAb5QMgoOFE
MBvlAzCC4AMAoOFgEBvlZCAb5fD6/+sBAADqYDAb5UQwC+UIMNvlBABT4wIAABpAMBvlODAL5QEA
AOo8MBvlODAL5TgwG+VIMAvltwAA6ggw2+VUIEviXAAb5QMQoOFT/v/rADCg4SAwC+UgMBvlAABT
4wIAAKogMBvleDAL5bYAAOo4MBvlAxCg4QAgoONUMEviGACT6AFQoOECYKDhA1CV4ARgpuB0UAvl
cGAL5SQwG+UDEKDhwS+g4WwQC+VoIAvlcCAb5WgwG+UDAFLhCAAAynBQG+VoYBvlBgBV4Q0AABp0
EBvlbCAb5QIAUeEAAACKCAAA6nQyn+UAMJPldAKf5QEQoOMfIKDjuPr/6wAw4ON4MAvlkAAA6iAw
G+UAAFPjCQAACkAwG+UDEKDhACCg41QwS+IYAJPoATCT4AJApOBUMAvlUEAL5XcAAOpUMEviGACT
6EwwC+VMMEviXAAb5RQSn+UDIKDhlPr/60wwS+JcABvlBBKf5QMgoOGP+v/rADCg4QAAU+MUAAAK
3DGf5QBQk+VYMBvlAzGg4YMhoOECMIPgwCGf5QJAg+Ck+v/rADCg4QAwk+UDAKDhXvr/6wAwoOEF
AKDhtBGf5QQgoOGJ+v/rAFDg43hQC+VeAADqVDBL4hgAk+hcABvlAxCg4QAgoOOJ+v/rADCg4QEA
c+MUAAAaZDGf5QBQk+VYMBvlAzGg4YMhoOECMIPgSCGf5QJAg+CG+v/rADCg4QAwk+UDAKDhQPr/
6wAwoOEFAKDhQBGf5QQgoOFr+v/rAGDg43hgC+VAAADqNCAb5UQwG+UDMILgXAAb5QMQoOE4IBvl
T/r/6wAwoOEDIKDhODAb5QMAUuEUAAAK4DCf5QBQk+VYMBvlAzGg4YMhoOECMIPgxCCf5QJAg+Bl
+v/rADCg4QAwk+UDAKDhH/r/6wAwoOEFAKDhwBCf5QQgoOFK+v/rABDg43gQC+UfAADqTDBL4lwA
G+WkEJ/lAyCg4TP6/+s0IBvlQDAb5QMwguA0MAvlADCg4ygwC+VAMBvlAxCg4QAgoONUMEviGACT
6AEwk+ACQKTgVDAL5VBAC+U0IBvlMDAb5QMAUuFD//86MCAb5WQwG+UDAFLhAQAAmkQAG+UR+v/r
NCAb5XggC+V4MBvlAwCg4RjQS+JwqJ3oeDsBAHA7AQCwtgAAzLYAAAZNCEACTQhA7LYAAAi3AAAg
twAABU0IQA3AoOEA2C3pBLBM4hjQTeIYAAvlHBAL5SAgC+UcABvlIBAb5QAgoOMX+v/rADCg4RAw
C+UQMBvlAABT4w4AAKp4MJ/lABCT5RgwG+UDMaDhgyGg4QIwg+BkIJ/lAjCD4AEAoOFcEJ/lAyCg
4f35/+sQMBvlJDAL5QwAAOocABvlRBCf5QEgoOPk+f/rADCg4RAwC+UQMBvlAABT4wEAAKooAJ/l
1Pn/6xAwG+UkMAvlJDAb5QMAoOEM0EviAKid6HA7AQB4OwEAOLcAANg7AQBctwAADcCg4RDYLekE
sEziLNBN4iAAC+UkEAvlKCAL5bQxn+UQMJPlMDAL5TAwG+UBAFPjDQAACjAwG+UBAFPjGwAAOjAw
G+UCAFPjAAAACgwAAOqAMZ/lCCCT5QAw0uUBMIPi/zAD4gAwwuUQAADqZDGf5Qggk+VgMZ/lADDT
5QAwwuUKAADqVDGf5QAgk+VEMZ/lEDCT5QIAoOFEEZ/lAyCg4bv5/+sAMODjLDAL5UUAAOogMZ/l
AMCT5Sgxn+UAMJPlJBGf5RQAoOMDMaDhgyGg4QIwg+ABMIPgADCD4ADgk+UoMBvlABGf5RAAoOMD
MaDhgyGg4QIwg+ABMIPgADCD4AAwk+UDQKDhKDAb5dgQn+UgAKDjAzGg4YMhoOECMIPgATCD4AAw
g+AAMNPlAECN5QQwjeUoABvlJBAb5QwgoOEOMKDhHP7/6wAwoOEcMAvlHDAb5QAAU+MCAACqHDAb
5SwwC+UXAADqaDCf5RAwk+UBAFPjEQAAGmgwn+UAMJPlZBCf5RAAoOMDMaDhgyGg4QIwg+ABMIPg
ADCD4AAwk+UEMIPiGDAL5Tgwn+UAMJPlAwCg4SAQG+UYIBvlWv//6wAwoOMsMAvlLDAb5QMAoOEQ
0EviEKid6MA7AQCsOgEAcDsBAHi3AADcOwEAeDsBAA3AoOEQ2C3pBLBM4kTQTeJAAAvlODBL4kAA
G+WEEZ/lAyCg4U/5/+sAMKDhGDAL5RgwG+UAAFPjBAAAqmgBn+U8+f/rADDg40gwC+VRAADqODBb
5QMAU+MMAAAKODBb5QQAU+MJAAAKQDGf5QAgk+U4MFvlAgCg4TQRn+UDIKDhR/n/6wAw4ONIMAvl
QQAA6iAxn+UAMJPlOBBb5RgBn+UgwKDjAzGg4YMhoOECMIPgADCD4Awgg+ABMKDhADDC5fAwn+UA
wJPl8DCf5QDgk+XgMJ/lADCT5dwQn+UUAKDjAzGg4YMhoOECMIPgATCD4AAwg+AAQJPluDCf5QAw
k+W0EJ/lEACg4wMxoOGDIaDhAjCD4AEwg+AAMIPgADCT5TggW+UAMI3lBCCN5QwAoOFAEBvlDiCg
4QQwoOGs/P/rADCg4RgwC+UYwBvlZDCf5QAwk+VgEJ/lFACg4wMxoOGDIaDhAjCD4AEwg+AAMIPg
ADCT5QMAXOECAAAKADDg40QwC+UBAADqADCg40QwC+VEMBvlSDAL5UgwG+UDAKDhENBL4hConegB
TSCAmLcAAHA7AQC0twAA3DsBAHg7AQDAOwEADcCg4TDYLekEsEziGNBN4igAC+WMMp/lADCT5QMx
oOGDIaDhAjCD4Hwin+UCMIPgAwCg4SgQG+W1+P/rADCg4SQwC+UkMBvlAABT4xUAAKpYMp/lAFCT
5Ugyn+UAMJPlAzGg4YMhoOECMIPgOCKf5QJAg+Dr+P/rADCg4QAwk+UDAKDhpfj/6wAwoOEFAKDh
HBKf5QQgoOHQ+P/rADDg4ywwC+V7AADqKDAb5QIAU+NXAAAa/DGf5QAwk+UAAFPjKgAACtwxn+UA
IJPlADCg4xgwC+UAAFLjAQAAGgEwoOMYMAvlGDAb5QMxoOGDIaDhAjCD4LAhn+UCMIPgAwCg4SgQ
G+WC+P/rADCg4SAwC+UgMBvlAABT4xkAAKqMMZ/lAFCT5RgwG+UDMaDhgyGg4QIwg+BwIZ/lAkCD
4Ln4/+sAMKDhADCT5QMAoOFz+P/rADCg4QUAoOFUEZ/lBCCg4Z74/+sAMODjHDAL5SwAAOowMZ/l
ADCT5RgwC+UkMBvlIDAL5SQAG+UgEBvlGCAb5a3+/+sAMKDhHDAL5RQxn+UAMJPlAABT4x0AAAog
ABvlhPj/6wAwoOEAAFPjGAAACugwn+UAUJPlGDAb5QMxoOGDIaDhAjCD4Mwgn+UCQIPgkPj/6wAw
oOEAMJPlAwCg4Ur4/+sAMKDhBQCg4bgQn+UEIKDhdfj/6wAw4OMcMAvlAwAA6iQAG+UH///rADCg
4RwwC+UkABvlZvj/6wAwoOEAAFPjFQAACnAwn+UAUJPlYDCf5QAwk+UDMaDhgyGg4QIwg+BQIJ/l
AkCD4HH4/+sAMKDhADCT5QMAoOEr+P/rADCg4QUAoOE8EJ/lBCCg4Vb4/+sAMODjLDAL5QEAAOoc
MBvlLDAL5SwwG+UDAKDhFNBL4jConejcOwEAeDsBAHA7AQDQtwAA1DsBAOS3AAANwKDhANgt6QSw
TOIg0E3iEAAL5RQQC+URAADqEDAb5QAg0+UAMKDjJDBL5T0AUuMBAAAaATCg4yQwS+UkIFvl/zAC
4hAgG+UBIILiECAL5QAAU+MCAAAKFDAb5RgwC+UeAADqEDAb5QAQ0+UUMBvlACDT5QAwoOMsMEvl
AgBR4QEAABoBMKDjLDBL5SwgW+X/MALiFCAb5QEgguIUIAvlAABT49z//xoQMBvlADDT5QAAU+MH
AAAaFDAb5QEwQ+IAMNPlPQBT4wIAABoUMBvlGDAL5QEAAOoAIKDjGCAL5RgwG+UDAKDhDNBL4gCo
negNwKDhENgt6QSwTOI80E3i3wEA6wAwoOEAAFPjAgAACgAg4ONMIAvlyQEA6jA3n+UAMJPlLBef
5RQAoOMDMaDhgyGg4QIwg+ABMIPgADCD4AAwk+UBAKDjAxCg4dL3/+sAMKDhMDAL5TAwG+UAAFPj
EgAAGvA2n+UAwJPl4Daf5QAwk+XcFp/lFACg4wMxoOGDIaDhAjCD4AEwg+AAMIPgADCT5QwAoOHA
Fp/lAyCg4d73/+sAMODjTDAL5aQBAOqsJp/lMDAb5QAwguWkNp/lADCT5QAAU+MNAAAKMDAb5Rgw
C+UYIBvlhDaf5QQgg+UYMBvlBCCD4nQ2n+UIIIPlGDAb5QUgg+JkNp/lDCCD5QsAAOowMBvlHDAL
5RwgG+VMNp/lBCCD5UQmn+UAMKDjCDCC5RwwG+UEIIPiMDaf5Qwgg+UYNp/lACCg4wAgg+UAAKDj
vf7/6wAwoOEAAFPjAgAACgAg4ONMIAvleAEA6vw1n+UMMJPlA0Cg4eH4/+sAMKDhAACg4wQQoOED
IKDh7/f/6wAwoOE8MAvlPBAb5cw1n+UEMJPlACCT5QAwoOM4MAvlAgBR4QEAABoBMKDjODAL5aw1
n+UAMJPlAABT4w8AABo4MBvlAABT41oBABqENZ/lADCT5YwFn+UBEKDjLCCg44r3/+t0NZ/lDDCT
5QMAoOF0FZ/ltCCg4373/+tNAQDqWDWf5Qgwk+UAMNPlMTBL5Tgln+UBMKDjADCC5Sw1n+UAMJPl
KBWf5RQAoOMDMaDhgyGg4QIwg+ABMIPgADCD4AAwk+UBAKDjAxCg4VH3/+sAMKDhIDAL5SAwG+UA
AFPjEgAAGuw0n+UAwJPl3DSf5QAwk+XYFJ/lFACg4wMxoOGDIaDhAjCD4AEwg+AAMIPgADCT5QwA
oOG8FJ/lAyCg4V33/+sAMODjTDAL5SMBAOogMBvlGDAL5aAkn+UgMBvlADCC5QAAoONb/v/rADCg
4QAAU+MCAAAKACDg40wgC+UWAQDqZDSf5QAwk+VgFJ/lIACg4wMxoOGDIaDhAjCD4AEwg+AAMIPg
ADDT5QMAU+MWAAAaNDSf5QAwk+UAIKDjSCAL5QAAU+MBAAAaATCg40gwC+UYFJ/lIACg40gwG+UD
MaDhgyGg4QIwg+ABMIPgADCD4AAw0+UDAFPjAwAAGvgjn+UBMKDjEDCC5SsAAOrYM5/lADCT5dQT
n+UgAKDjAzGg4YMhoOECMIPgATCD4AAwg+AAMNPlBABT4xYAABqoM5/lADCT5QAgoONEIAvlAABT
4wEAABoBMKDjRDAL5YwTn+UgAKDjRDAb5QMxoOGDIaDhAjCD4AEwg+AAMIPgADDT5QQAU+MDAAAa
bCOf5QIwoOMQMILlCAAA6lQzn+UAMJPlZAOf5QEQoOMaIKDj/vb/6wAg4ONMIAvlxwAA6hgwG+UF
MIPiA0Cg4TD4/+sAMKDhAACg4wQQoOEDIKDhPvf/6wAwoOEsMAvlLBAb5RgwG+UAIJPlADCg4ygw
C+UCAFHhAQAAGgEwoOMoMAvlGDAb5QQw0+UhMEvlODAb5QAAU+MGAAAKKDAb5QAAU+MDAAAatCKf
5QAwoOMAMILligAA6jgwG+UAAFPjBgAAGigwG+UAAFPjAwAACowin+UBMKDjADCC5YAAAOo4MBvl
AABT4xIAABooMBvlAABT4w8AABpsMp/lADCT5XQCn+UBEKDjLCCg48T2/+tcMp/lDDCT5QMAoOFc
Ep/ltCCg47j2/+s0Ip/lADCg4wAwguVqAADqNDKf5RAwk+VAMAvlQDAb5QEAU+MDAAAKQCAb5QIA
UuM2AAAKVQAA6iAyn+UAINPlMTBb5QIAU+EIAAAaEDKf5QAg0+UhMFvlAgBT4QMAABrUIZ/lADCg
4wAwguVSAADq7DGf5QAg0+UxMFvlAgBT4QgAABrUMZ/lACDT5SEwW+UCAFPhAwAAGpwhn+UBMKDj
ADCC5UQAAOoxIFvlITBb5QMAUuEDAAAafCGf5QAwoOMAMILlPAAA6jEwW+X/AFPjAwAAGmAhn+UA
MKDjADCC5TUAAOohMFvl/wBT4wMAABpEIZ/lATCg4wAwguUuAADqNCGf5QAwoOMAMILlKgAA6jEw
W+X/AFPjAgAAGiEwW+UAAFPjAwAACiEgW+UxMFvlAwBS4QMAAJr8IJ/lATCg4wAwguUcAADqITBb
5f8AU+MCAAAaMTBb5QAAU+MDAAAKMSBb5SEwW+UDAFLhAwAAmsQgn+UAMKDjADCC5Q4AAOq0IJ/l
ADCg4wAwguUKAADqrDCf5QAgk+WsMJ/lEDCT5QIAoOG8EJ/lAyCg4VX2/+sAMODjTDAL5RsAAOp4
MJ/lADCT5QAAU+MQAAAKeCCf5SAwG+UAMILlGCAb5Wgwn+UEIIPlGDAb5QQgg+JYMJ/lCCCD5Rgw
G+UFIIPiSDCf5Qwgg+UwABvlJvb/6wQAAOo0IJ/lMDAb5QAwguUgABvlIPb/6wAgoONMIAvlTDAb
5QMAoOEQ0EviEKid6Nw7AQB4OwEAcDsBAPy3AADAOwEA1DsBACy4AACwOgEAXLgAAKw6AQDYOwEA
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
bm1lbnQgbm90IHRlcm1pbmF0ZWQKAAAALW4AACMjIEVycm9yOiBgLW4nIG9wdGlvbiByZXF1aXJl
cyBleGFjdGx5IG9uZSBhcmd1bWVudAoAAAAAIyMgRXJyb3I6ICIlcyIgbm90IGRlZmluZWQKAGV0
aGFkZHIAc2VyaWFsIwBDYW4ndCBvdmVyd3JpdGUgIiVzIgoAAABFcnJvcjogZW52aXJvbm1lbnQg
b3ZlcmZsb3csICIlcyIgZGVsZXRlZAoAAEVycm9yOiBjYW4ndCB3cml0ZSBmd19lbnYgdG8gZmxh
c2gKAENhbm5vdCByZWFkIGJhZCBibG9jayBtYXJrAABUb28gZmV3IGdvb2QgYmxvY2tzIHdpdGhp
biByYW5nZQoAAABSZWFkIGVycm9yIG9uICVzOiAlcwoAAABDYW5ub3QgbWFsbG9jICV1IGJ5dGVz
OiAlcwoARW5kIG9mIHJhbmdlIHJlYWNoZWQsIGFib3J0aW5nCgBNVEQgZXJhc2UgZXJyb3Igb24g
JXM6ICVzCgAAU2VlayBlcnJvciBvbiAlczogJXMKAAAAV3JpdGUgZXJyb3Igb24gJXM6ICVzCgAA
Q2Fubm90IHNlZWsgdG8gc2V0IHRoZSBmbGFnIG9uICVzIAoAQ291bGQgbm90IHNldCBvYnNvbGV0
ZSBmbGFnAFVuaW1wbGVtZW50ZWQgZmxhc2ggc2NoZW1lICV1IAoAQ2Fubm90IGdldCBNVEQgaW5m
b3JtYXRpb24AAFVuc3VwcG9ydGVkIGZsYXNoIHR5cGUgJXUKAABDYW4ndCBvcGVuICVzOiAlcwoA
AEkvTyBlcnJvciBvbiAlczogJXMKAAAAAE5vdCBlbm91Z2ggbWVtb3J5IGZvciBlbnZpcm9ubWVu
dCAoJWxkIGJ5dGVzKQoAAFdhcm5pbmc6IEJhZCBDUkMsIHVzaW5nIGRlZmF1bHQgZW52aXJvbm1l
bnQKAAAAAEluY29tcGF0aWJsZSBmbGFzaCB0eXBlcyEKAABVbmtub3duIGZsYWcgc2NoZW1lICV1
IAoAAAAAL2Rldi9tdGQxAAAAQ2Fubm90IGFjY2VzcyBNVEQgZGV2aWNlICVzOiAlcwoAAAAAZndf
cHJpbnRlbnYAZndfc2V0ZW52AAAASWRlbnRpdHkgY3Jpc2lzIC0gbWF5IGJlIGNhbGxlZCBhcyBg
ZndfcHJpbnRlbnYnIG9yIGFzIGBmd19zZXRlbnYnIGJ1dCBub3QgYXMgYCVzJwoAIM7/fwEAAAAA
AAAA3IcAALyHAAAAAAAAAQAAABAAAAAMAAAA/IUAAA0AAABMsQAAGQAAADw5AQAbAAAABAAAABoA
AABAOQEAHAAAAAQAAAAEAAAAaIEAAAUAAADkgwAABgAAACSCAAAKAAAA3QAAAAsAAAAQAAAAFQAA
AAAAAAADAAAAMDoBAAIAAADIAAAAFAAAABEAAAAXAAAANIUAABEAAAAchQAAEgAAABgAAAATAAAA
CAAAAP7//2/8hAAA////bwEAAADw//9vwoQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAEg5AQAAAAAAAAAAABCGAAAQhgAAEIYAABCGAAAQhgAAEIYAABCG
AAAQhgAAEIYAABCGAAAQhgAAEIYAABCGAAAQhgAAEIYAABCGAAAQhgAAEIYAABCGAAAQhgAAEIYA
ABCGAAAQhgAAEIYAABCGAAAAAAAAAAAAAAAAAAABAAAAYm9vdGNtZD1ib290cDsgc2V0ZW52IGJv
b3RhcmdzIHJvb3Q9L2Rldi9uZnMgbmZzcm9vdD0ke3NlcnZlcmlwfToke3Jvb3RwYXRofSBpcD0k
e2lwYWRkcn06JHtzZXJ2ZXJpcH06JHtnYXRld2F5aXB9OiR7bmV0bWFza306JHtob3N0bmFtZX06
Om9mZjsgYm9vdG0AYm9vdGRlbGF5PTUAYmF1ZHJhdGU9MTE1MjAwAAAAAEdDQzogKEdOVSkgNC4y
LjEAAEdDQzogKEdOVSkgNC4yLjEAAEdDQzogKEdOVSkgNC4yLjEAAEdDQzogKEdOVSkgNC4yLjEA
AEdDQzogKEdOVSkgNC4yLjEAAEdDQzogKEdOVSkgNC4yLjEAAEdDQzogKEdOVSkgNC4yLjEAAEdD
QzogKEdOVSkgNC4yLjEAAEdDQzogKEdOVSkgNC4yLjEAAEdDQzogKEdOVSkgNC4yLjEALAAAAAIA
AAAAAAQAAAAAAIiHAAA0AAAA/IUAABAAAABMsQAADAAAAAAAAAAAAAAAJAAAAAIA9AAAAAQAAAAA
AAyGAAAEAAAAWLEAAAQAAAAAAAAAAAAAAPAAAAACAAAAAAAEAQAAAAAAAAAAL2hvbWUvc2xhdmEv
dG9vbGNoYWluX2J1aWxkL2Nyb3NzdG9vbC9idWlsZC9hcm0tbm9uZS1saW51eC1nbnVlYWJpL2dj
Yy00LjItZ2xpYmMtMi41L2J1aWxkLWdsaWJjL2NzdS9jcnRpLlMAL2hvbWUvc2xhdmEvdG9vbGNo
YWluX2J1aWxkL2Nyb3NzdG9vbC9idWlsZC9hcm0tbm9uZS1saW51eC1nbnVlYWJpL2djYy00LjIt
Z2xpYmMtMi41L2dsaWJjLTIuNS9jc3UAR05VIEFTIDIuMTguNTAAAYDwAAAAAgASAAAABAHJAAAA
KAAAAC9ob21lL3NsYXZhL3Rvb2xjaGFpbl9idWlsZC9jcm9zc3Rvb2wvYnVpbGQvYXJtLW5vbmUt
bGludXgtZ251ZWFiaS9nY2MtNC4yLWdsaWJjLTIuNS9idWlsZC1nbGliYy9jc3UvY3J0bi5TAC9o
b21lL3NsYXZhL3Rvb2xjaGFpbl9idWlsZC9jcm9zc3Rvb2wvYnVpbGQvYXJtLW5vbmUtbGludXgt
Z251ZWFiaS9nY2MtNC4yLWdsaWJjLTIuNS9nbGliYy0yLjUvY3N1AEdOVSBBUyAyLjE4LjUwAAGA
AREAEAZVBgMIGwglCBMFAAAAAREAEAZVBgMIGwglCBMFAAAAxQAAAAIAggAAAAIB+w4NAAEBAQEA
AAABAAABL2hvbWUvc2xhdmEvdG9vbGNoYWluX2J1aWxkL2Nyb3NzdG9vbC9idWlsZC9hcm0tbm9u
ZS1saW51eC1nbnVlYWJpL2djYy00LjItZ2xpYmMtMi41L2J1aWxkLWdsaWJjL2NzdQAAY3J0aS5T
AAEAAAAABQKIhwAAAxYBLy8vMC8vLy8vMAIGAAEBAAUC/IUAAAMwAS8vLwICAAEBAAUCTLEAAAPB
AAEvLwICAAEBpgAAAAIAggAAAAIB+w4NAAEBAQEAAAABAAABL2hvbWUvc2xhdmEvdG9vbGNoYWlu
X2J1aWxkL2Nyb3NzdG9vbC9idWlsZC9hcm0tbm9uZS1saW51eC1nbnVlYWJpL2djYy00LjItZ2xp
YmMtMi41L2J1aWxkLWdsaWJjL2NzdQAAY3J0bi5TAAEAAAAABQIMhgAAAxIBAgIAAQEABQJYsQAA
AxkBAgIAAQEA/////wAAAACIhwAAvIcAAPyFAAAMhgAATLEAAFixAAAAAAAAAAAAAP////8AAAAA
DIYAABCGAABYsQAAXLEAAAAAAAAAAAAAQS4AAABhZWFiaQABJAAAAAVBUk0xMFRETUkABgQIAQkB
EgQUARUBFwMYARkBGgIALnN5bXRhYgAuc3RydGFiAC5zaHN0cnRhYgAuaW50ZXJwAC5ub3RlLkFC
SS10YWcALmhhc2gALmR5bnN5bQAuZHluc3RyAC5nbnUudmVyc2lvbgAuZ251LnZlcnNpb25fcgAu
cmVsLmR5bgAucmVsLnBsdAAuaW5pdAAudGV4dAAuZmluaQAucm9kYXRhAC5BUk0uZXhpZHgALmVo
X2ZyYW1lAC5pbml0X2FycmF5AC5maW5pX2FycmF5AC5qY3IALmR5bmFtaWMALmdvdAAuZGF0YQAu
YnNzAC5jb21tZW50AC5kZWJ1Z19hcmFuZ2VzAC5kZWJ1Z19pbmZvAC5kZWJ1Z19hYmJyZXYALmRl
YnVnX2xpbmUALmRlYnVnX3JhbmdlcwAuQVJNLmF0dHJpYnV0ZXMAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABsAAAABAAAAAgAAADSBAAA0AQAAEwAAAAAAAAAAAAAA
AQAAAAAAAAAjAAAABwAAAAIAAABIgQAASAEAACAAAAAAAAAAAAAAAAQAAAAAAAAAMQAAAAUAAAAC
AAAAaIEAAGgBAAC8AAAABAAAAAAAAAAEAAAABAAAADcAAAALAAAAAgAAACSCAAAkAgAAwAEAAAUA
AAABAAAABAAAABAAAAA/AAAAAwAAAAIAAADkgwAA5AMAAN0AAAAAAAAAAAAAAAEAAAAAAAAARwAA
AP///28CAAAAwoQAAMIEAAA4AAAABAAAAAAAAAACAAAAAgAAAFQAAAD+//9vAgAAAPyEAAD8BAAA
IAAAAAUAAAABAAAABAAAAAAAAABjAAAACQAAAAIAAAAchQAAHAUAABgAAAAEAAAAAAAAAAQAAAAI
AAAAbAAAAAkAAAACAAAANIUAADQFAADIAAAABAAAAAsAAAAEAAAACAAAAHUAAAABAAAABgAAAPyF
AAD8BQAAFAAAAAAAAAAAAAAABAAAAAAAAABwAAAAAQAAAAYAAAAQhgAAEAYAAEABAAAAAAAAAAAA
AAQAAAAEAAAAewAAAAEAAAAGAAAAUIcAAFAHAAD8KQAAAAAAAAAAAAAEAAAAAAAAAIEAAAABAAAA
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
9AQAACyHAAA0AAAAEgAAAAYFAAA4hwAAHAAAABIAAAAiBQAAlK8AACABAAASAAwAJwUAAPyFAAAA
AAAAEgAKAC0FAABEhwAAkAIAABIAAAAAaW5pdGZpbmkuYwBjYWxsX2dtb25fc3RhcnQAJGEAJGQA
aW5pdC5jAGNydHN0dWZmLmMAX19KQ1JfTElTVF9fAF9fZG9fZ2xvYmFsX2R0b3JzX2F1eABjb21w
bGV0ZWQuNjI2MgBfX2RvX2dsb2JhbF9kdG9yc19hdXhfZmluaV9hcnJheV9lbnRyeQBmcmFtZV9k
dW1teQBfX2ZyYW1lX2R1bW15X2luaXRfYXJyYXlfZW50cnkAY3JjMzIuYwBjcmNfdGFibGUAZndf
ZW52LmMAZW52ZGV2aWNlcwBlbnZpcm9ubWVudABIYXZlUmVkdW5kRW52AGFjdGl2ZV9mbGFnAG9i
c29sZXRlX2ZsYWcAZGVmYXVsdF9lbnZpcm9ubWVudABlbnZfaW5pdABnZXRlbnZzaXplAGVudm1h
dGNoAGRldl9jdXJyZW50AGZsYXNoX2lvAGZsYXNoX2JhZF9ibG9jawBmbGFzaF9yZWFkX2J1ZgBm
bGFzaF93cml0ZV9idWYAZmxhc2hfZmxhZ19vYnNvbGV0ZQBmbGFzaF93cml0ZQBmbGFzaF9yZWFk
AHBhcnNlX2NvbmZpZwBmd19lbnZfbWFpbi5jAGVsZi1pbml0LmMAc3RhdC5jAF9fRlJBTUVfRU5E
X18AX19KQ1JfRU5EX18AX0dMT0JBTF9PRkZTRVRfVEFCTEVfAF9faW5pdF9hcnJheV9lbmQAX19p
bml0X2FycmF5X3N0YXJ0AF9EWU5BTUlDAGRhdGFfc3RhcnQAb3BlbkBAR0xJQkNfMi40AHN0cmVy
cm9yQEBHTElCQ18yLjQAYWJvcnRAQEdMSUJDXzIuNABfX2xpYmNfY3N1X2ZpbmkAX3N0YXJ0AF9f
eHN0YXRAQEdMSUJDXzIuNABfX2xpYmNfc3RhcnRfbWFpbkBAR0xJQkNfMi40AF9fZ21vbl9zdGFy
dF9fAF9Kdl9SZWdpc3RlckNsYXNzZXMAX2ZpbmkAY2FsbG9jQEBHTElCQ18yLjQAZndfcHJpbnRl
bnYAc3RycmNockBAR0xJQkNfMi40AHBlcnJvckBAR0xJQkNfMi40AF9fc3RhdABzdGF0AF9JT19z
dGRpbl91c2VkAGZ3X2dldGVudgBmcmVlQEBHTElCQ18yLjQAcmVhZEBAR0xJQkNfMi40AHdyaXRl
QEBHTElCQ18yLjQAX19kYXRhX3N0YXJ0AGNyYzMyAF9fYnNzX3N0YXJ0X18AaW9jdGxAQEdMSUJD
XzIuNABzdHJsZW5AQEdMSUJDXzIuNABfX2V4aWR4X2VuZABtZW1jcHlAQEdMSUJDXzIuNABfX2Rz
b19oYW5kbGUAX19lbmRfXwBfX2xpYmNfY3N1X2luaXQAX19ic3NfZW5kX18AY2xvc2VAQEdMSUJD
XzIuNABmd3JpdGVAQEdMSUJDXzIuNABmd19zZXRlbnYAX19ic3Nfc3RhcnQAZnByaW50ZkBAR0xJ
QkNfMi40AG1hbGxvY0BAR0xJQkNfMi40AF9ic3NfZW5kX18AcHV0c0BAR0xJQkNfMi40AF9lbmQA
c3Rkb3V0QEBHTElCQ18yLjQAc3RkZXJyQEBHTElCQ18yLjQAbHNlZWtAQEdMSUJDXzIuNABfZWRh
dGEAX0lPX3B1dGNAQEdMSUJDXzIuNABfX2V4aWR4X3N0YXJ0AHN0cmNtcEBAR0xJQkNfMi40AF9f
ZXJybm9fbG9jYXRpb25AQEdMSUJDXzIuNABtYWluAF9pbml0AGZwdXRzQEBHTElCQ18yLjQA
