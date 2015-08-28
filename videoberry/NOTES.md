#### Proot

Install the ```proot``` package.

Run emulation as follows:
```shell
kpartx -av <raspbian image>
mount /dev/mapper/loop0p2 /mnt/raspbian
mount /dev/mapper/loop0p1 /mnt/raspbian/boot
proot -q 'qemu-arm -cpu arm1176' -S /mnt/raspbian /bin/bash
```

#### Initrd

Create an initrd image (needs to be done after each kernel update):
```shell
update-initramfs -c -k <kernel version>
mv /boot/initrd.img-<kernel version> /boot/initramfs.gz
```

Tell the firmware to use the initrd by adding the following line to ```/boot/config.txt``` (this only needs to be done once):
```
initramfs initramfs.gz 0x0a000000
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
mv /boot/initrd.img-<kernel version> /boot/initramfs.gz
```

#### Presenter

Add the following lines to the ```/etc/inittab```:
```
# Spawn PI Media Presenter on tty1
mp:23:respawn:/etc/init.d/pi_media_presenter tty1
```
