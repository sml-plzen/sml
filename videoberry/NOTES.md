#### Proot

Install the ```proot``` package.

Run emulation as follows:
```shell
kpartx -av <raspbian image>
mount /dev/mapper/loop0p2 /mnt/raspbian
mount /dev/mapper/loop0p1 /mnt/raspbian/boot
proot -q 'qemu-arm -cpu arm1176' -S /mnt/raspbian /bin/bash
```

#### Kernel

Checkout sources:
```shell
git clone https://github.com/raspberrypi/linux
cd linux
git checkout <branch supporting PI v1>
```

Enable CONFIG_CIFS_UPCALL:
```diff
--- a/arch/arm/configs/bcmrpi_defconfig
+++ b/arch/arm/configs/bcmrpi_defconfig
@@ -1122,6 +1122,7 @@ CONFIG_NFSD_V3_ACL=y
 CONFIG_NFSD_V4=y
 CONFIG_CIFS=m
 CONFIG_CIFS_WEAK_PW_HASH=y
+CONFIG_CIFS_UPCALL=y
 CONFIG_CIFS_XATTR=y
 CONFIG_CIFS_POSIX=y
 CONFIG_9P_FS=m
 ```

Build the kernel (in the proot emulation environment):
```shell
proot -q 'qemu-arm -cpu arm1176' -S /mnt/raspbian /bin/bash
LANG=en_GB.UTF-8
make bcmrpi_defconfig

make zImage modules # dtbs
make modules_install
```

Mark the kernel as device tree capable:
```shell
scripts/mkknlimg arch/arm/boot/zImage kernel.img
```

Transfer kernel image and modules:
```shell
rsync -vrltH --del kernel.img  videoberry:/boot/kernel-<kernel version>.img
rsync -vrltH --del /lib/modules/<kernel version>/  videoberry:/lib/modules/<kernel version>/
# rsync -vrltH arch/arm/boot/dts/*.dtb videoberry:/boot/
# rsync -vrltHarch/arm/boot/dts/overlays/*.dtb* videoberry:/boot/overlays/
# rsync -vrltH arch/arm/boot/dts/overlays/README videoberry:/boot/overlays/
```

Prepare the kernel:
```shell
depmod -a <kernel version>
update-initramfs -c -k <kernel version>
mv /boot/initrd.img-<kernel version> /boot/initramfs-<kernel version>.gz
```

Tell the firmware to boot the kernel by adding the following lines to ```/boot/config.txt```:
```
kernel=kernel-<kernel version>.img
initramfs initramfs-<kernel version>.gz 0x0a000000
```

#### Samba

Build a version of ```samba``` providing the ```winbind_krb5_locator.so``` kerberos plugin:
```shell
cd debbuild/src
wget http://security.debian.org/debian-security/pool/updates/main/s/samba/samba_3.6.6.orig.tar.bz2
dpkg-source -x samba_3.6.6-6+loc+deb7u5.dsc
cd samba-3.6.6
proot -q 'qemu-arm -cpu arm1176' -S /mnt/raspbian /bin/bash
LANG=en_GB.UTF-8
dpkg-buildpackage -uc -us
```

Install the ```winbind``` package:
```shell
dpkg -i winbind_3.6.6-6+loc+deb7u5_armhf.deb samba-common_3.6.6-6+loc+deb7u5_all.deb samba-common-bin_3.6.6-6+loc+deb7u5_armhf.deb
```

Join the box to the domain:
```shell
net ads join -U Administrator
```

#### Plymouth

Disable the ```plymouth``` service:
```
update-rc.d -f plymouth remove
```

Add the following kernel command line parameters to ```/boot/cmdline.txt```:
```
logo.nologo quiet splash plymouth.ignore-serial-consoles
```

Activate the ```sml``` theme:
```shell
plymouth-set-default-theme sml
update-initramfs -c -k <kernel version>
mv /boot/initrd.img-<kernel version> /boot/initramfs-<kernel version>.gz
```

#### Presenter

Add the following lines to the ```/etc/inittab```:
```
# Spawn PI Media Presenter on tty1
mp:23:respawn:/etc/init.d/pi_media_presenter tty1
```
