# Install and configure yay

```bash
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si

# generate a development package database for *-git packages that were installed without yay
yay -Y --gendb

# check for development package updates
yay -Syu --devel

# make development package updates permanently enabled (yay and yay -Syu will then always check dev packages)
yay -Y --devel --save
```

# Enable ssh agent

```bash
systemctl --user enable --now ssh-agent.socket
```

Set SSH_AUTH_SOCKET in ~/.bashrc:

```bash
# Don't overwrite SSH_AUTH_SOCK if it's coming from an ssh connection, otherwise agent forwarding breaks
if [[ -z "${SSH_CONNECTION}" ]]; then
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
fi
```

# Enable TPM auto-unlock of LUKS encrypted disk

Suggested only for desktop machines that never leave the house.
Only using PCR 7 is not full protection, but it's good enough for now

```bash
systemd-cryptenroll /dev/nvme0n1p2 --tpm2-device=auto --tpm2-pcrs=7:sha256
```