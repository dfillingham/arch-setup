# arch-setup

## Overview

An installation script with prebuilt configuration files for the way I like to setup my Arch workstation machines.

## Notes

* Script doesn't check for it, but this only works on EFI systems
* `systemd-boot` is added even though a UKI is created and set as the EFI boot option
    * On laptops I create a rescue image and it's nice to have a selection menu with the ability to override kernel command line if neccesary
* The root user's password is set to `password`, don't forget to change it!
