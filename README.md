# Physical Disk Emulation
Example script to setup a virtual disk that emulates the physical layout.
It is *not* intended to be run without modification.

## Disclaimer
This script is dangerous and can make you loose data. Use it at your own risk.
Also, it probably will mess up with your windows activation.

## Goal
In order to run an existing windows instalation through
[QEMU](https://wiki.archlinux.org/title/QEMU), one needs to pass the whole
disk to windows or else it won't work. If the disk is only used by windows,
you are fine, just pass it. However, if you need some partition(s) of the disk
on your linux host, you need to trick windows into thinking it has the entire
disk for itself. For that we use loop devices and virtual mappings. Read the
script to understand it and modify to your needs.
