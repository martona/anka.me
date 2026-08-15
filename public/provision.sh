#!/usr/bin/env bash
#
#   provision.sh - one-off Linux box provisioning steps
#   ---------------------------------------------------
#   The Linux sibling of provision.ps1. Run as your regular user (steps
#   sudo on their own where needed); with no args it shows a menu, with
#   --all it runs everything except the interactive steps. Unlike the
#   Windows script, every step prints each command before running it.
#
#       curl -fsSL https://anka.me/provision.sh | bash
#       curl -fsSL https://anka.me/provision.sh | bash -s -- --all
#
#   Debian/Ubuntu only (apt). Prompts read /dev/tty, so the curl | bash
#   form stays interactive.

set -u

# ---- pretty, uniform output ------------------------------------------------
C_GRN=$'\033[32m'; C_BGRN=$'\033[92m'; C_CYN=$'\033[96m'; C_YEL=$'\033[93m'
C_RED=$'\033[91m'; C_GRY=$'\033[90m'; C_WHT=$'\033[97m'; C_OFF=$'\033[0m'

Section () { echo; printf '  %s%s%s\n' "$C_GRN" "$1" "$C_OFF"; printf '  %s%s%s\n' "$C_GRY" "$(printf -- '-%.0s' $(seq ${#1}))" "$C_OFF"; }
Step ()    { printf '%s==> %s%s%s\n' "$C_CYN" "$C_WHT" "$1" "$C_OFF"; }
Done ()    { printf '%s==> %s%s%s\n' "$C_GRN" "$C_WHT" "$1" "$C_OFF"; }
Note ()    { printf '    %s%s%s\n' "$C_GRY" "$1" "$C_OFF"; }
Warn ()    { printf '%s!   %s%s%s\n' "$C_YEL" "$C_WHT" "$1" "$C_OFF"; }
Fail ()    { printf '%sx   %s%s%s\n' "$C_RED" "$C_WHT" "$1" "$C_OFF"; }

# Every mutating command goes through one of these three, so it is shown
# before it runs. run for plain argv, runsh for pipelines/redirections,
# write_root_file for whole config files (prints the content too).
run () {
    printf '    %s$ %s%s\n' "$C_GRY" "$*" "$C_OFF"
    "$@"
}
runsh () {
    printf '    %s$ %s%s\n' "$C_GRY" "$1" "$C_OFF"
    bash -c "$1"
}
write_root_file () {
    local path="$1" content
    content=$(cat)
    printf '    %s$ sudo tee %s <<EOF%s\n' "$C_GRY" "$path" "$C_OFF"
    printf '%s\n' "$content" | sed "s/^/      ${C_GRY}/; s/\$/${C_OFF}/"
    printf '      %sEOF%s\n' "$C_GRY" "$C_OFF"
    printf '%s\n' "$content" | sudo tee "$path" >/dev/null
}

# Prompts must come from the terminal, not stdin: under curl | bash stdin
# is the script itself.
ask () {  # ask <varname> <prompt>
    local __v
    read -r -p "    $2" __v </dev/tty
    printf -v "$1" '%s' "$__v"
}

# ---- args ------------------------------------------------------------------
ALL=""; HELP=""
for a in "$@"; do
    case "$a" in
        --all|-all|/all)     ALL=1 ;;
        --help|-h|/?)        HELP=1 ;;
    esac
done
if [[ -n "$HELP" ]]; then
    echo
    printf '  %sprovision.sh - menu of Linux box setup steps.%s\n' "$C_WHT" "$C_OFF"
    Note 'run with no args for the menu, or --all to run everything unattended.'
    Note '--all skips the interactive steps (atuin, ssh key, yadm, clevis).'
    echo
    exit 0
fi

# ---- environment -----------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    Fail 'Run as your regular user, not root - steps sudo on their own, and'
    Fail 'the atuin/yadm/ssh-key steps configure the invoking user.'
    exit 1
fi
if ! command -v apt >/dev/null; then
    Fail 'This script is for Debian/Ubuntu (apt not found).'
    exit 1
fi
if [[ -z "$ALL" && ! -r /dev/tty ]]; then
    Fail 'No terminal available for the menu - use --all for unattended mode.'
    exit 1
fi

# ===========================================================================
#  the steps
# ===========================================================================

# 1) passwordless sudo for the current user, via a validated sudoers.d file
#    (never edits /etc/sudoers itself; visudo -cf gates the install).
step_sudo_nopasswd () {
    Step "Enabling passwordless sudo for $USER..."
    local f="/etc/sudoers.d/99-${USER}-nopasswd" tmp
    if [[ -e "$f" ]]; then Note "$f already exists - nothing to do."; return 0; fi
    tmp=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USER" > "$tmp"
    Note "writing: $USER ALL=(ALL) NOPASSWD: ALL"
    run sudo visudo -cf "$tmp"
    run sudo install -m 440 -o root -g root "$tmp" "$f"
    rm -f "$tmp"
    Done "Passwordless sudo enabled ($f)."
}

# 2) apt update + upgrade + the standard package set.
PKGS=( openssh-server smartmontools nvme-cli build-essential tmux mc cifs-utils
       lm-sensors clevis btop stress-ng glances s-tui rasdaemon ncdu ddpt curl
       fastfetch pv socat )
step_packages () {
    Step 'Updating, upgrading and installing the package set...'
    run sudo apt update
    run sudo apt -y upgrade
    if ! run sudo apt -y install "${PKGS[@]}"; then
        # a single unavailable package (e.g. fastfetch on older releases)
        # must not sink the whole set
        Warn 'Batch install failed - retrying one by one.'
        local p
        for p in "${PKGS[@]}"; do
            run sudo apt -y install "$p" || Warn "could not install $p"
        done
    fi
    Done 'Packages installed.'
}

# 3) authorized_keys from the martona GitHub account.
step_authkeys () {
    Step 'Importing authorized_keys from GitHub (martona)...'
    command -v ssh-import-id-gh >/dev/null || run sudo apt -y install ssh-import-id
    run ssh-import-id-gh martona
    Done 'GitHub keys imported into ~/.ssh/authorized_keys.'
}

# 4) saner grub: visible menu, 5s timeout, and no surprise infinite wait
#    after an unclean shutdown (RECORDFAIL). The hugepages/IOMMU line for
#    VM hosts is deliberately not automated - it is machine-specific.
set_grub_kv () {
    local key="$1" val="$2"
    if grep -q "^${key}=" /etc/default/grub; then
        runsh "sudo sed -i 's|^${key}=.*|${key}=${val}|' /etc/default/grub"
    else
        runsh "echo '${key}=${val}' | sudo tee -a /etc/default/grub >/dev/null"
    fi
}
step_grub () {
    Step 'Making grub saner (menu shown, 5s timeout, recordfail capped)...'
    set_grub_kv GRUB_TIMEOUT_STYLE menu
    set_grub_kv GRUB_TIMEOUT 5
    set_grub_kv GRUB_RECORDFAIL_TIMEOUT '$GRUB_TIMEOUT'
    run sudo update-grub
    Done 'grub updated.'
}

# 5) read-only: ECC/EDAC presence and error report (physical boxes).
step_ecc () {
    Step 'Checking ECC / EDAC state (read-only)...'
    if [[ ! -e /sys/devices/system/edac/mc/mc0 ]]; then
        Fail 'No EDAC memory controllers - no ECC visibility on this box (normal for a VM).'
        return 0
    fi
    run sudo ras-mc-ctl --summary || true
    run sudo ras-mc-ctl --errors  || true
    runsh "journalctl -k | grep -iE 'edac|mce|hardware error' | tail -n 20 || true"
    runsh "sudo dmesg | grep -iE 'edac|apei|ghes' | tail -n 20 || true"
    Done 'ECC diagnostics above; nothing was changed.'
}

# 6) long-fat-pipe TCP: big buffers, BBR. Written (not appended) so
#    re-runs stay idempotent.
step_tcp () {
    Step 'Tuning TCP (64MB buffers, BBR)...'
    write_root_file /etc/sysctl.d/99-fast-long-fat-tcp.conf <<'EOF'
# allow 64 MB socket buffers
net.core.rmem_max=67108864
net.core.wmem_max=67108864

# bump autotune ceilings (min / default / max)
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# better window ramp
net.ipv4.tcp_congestion_control=bbr
EOF
    run sudo modprobe tcp_bbr || true
    run sudo sysctl --system
    Done "TCP tuned; congestion control is now: $(sysctl -n net.ipv4.tcp_congestion_control)."
}

# 7) atuin - install only; login/sync stay manual on purpose.
step_atuin () {
    Step 'Installing atuin (shell history)...'
    Note 'The installer is interactive. Answer: Y (import existing shell'
    Note 'history), then n, n (decline the rest).'
    Note 'atuin login/sync is deliberately NOT automated - do it by hand later.'
    runsh "bash <(curl -fsSL https://raw.githubusercontent.com/atuinsh/atuin/main/install.sh) </dev/tty"
    Done 'atuin installed (new shells pick it up via the rc changes it made).'
}

# 8) bring over the personal ssh key (default/default.pub) from another
#    box - yadm and anything github-ssh needs it. scp prompts for the
#    password itself.
step_sshkey () {
    Step 'Importing ~/.ssh/default[.pub] from another box...'
    if [[ -f "$HOME/.ssh/default" ]]; then
        Note '~/.ssh/default already exists - nothing to do.'
        return 0
    fi
    local src
    ask src 'copy from (user@host, Enter cancels): '
    if [[ -z "$src" ]]; then Note 'Cancelled.'; return 0; fi
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"
    run scp "${src}:.ssh/default" "${src}:.ssh/default.pub" "$HOME/.ssh/"
    run chmod 600 "$HOME/.ssh/default"
    run chmod 644 "$HOME/.ssh/default.pub"
    Done "ssh key imported from $src."
}

# 9) yadm + neovim + git plumbing + dotfiles. The reset --hard after the
#    clone is the required "manual checkout": it clobbers the distro
#    default rc files with the dotfiles versions.
step_yadm () {
    Step 'Setting up yadm, neovim and the dotfiles...'
    run sudo apt -y install yadm neovim
    run git config --global user.email marton@anka.me
    run git config --global user.name marton
    run git config --global merge.tool nvimdiff
    run git config --global diff.tool nvimdiff
    run git config --global mergetool.keepBackup false
    run git config --global mergetool.prompt false
    run git config --global mergetool.nvimdiff.layout 'LOCAL,MERGED,REMOTE'
    run git config --global difftool.prompt false
    local themes="$HOME/.local/share/nvim/site/pack/themes/start/modus-themes.nvim"
    if [[ -d "$themes" ]]; then
        Note 'modus-themes already cloned.'
    else
        run mkdir -p "${themes%/*}"
        run git clone https://github.com/miikanissi/modus-themes.nvim "$themes"
    fi
    if [[ ! -f "$HOME/.ssh/default" ]]; then
        Warn 'No ~/.ssh/default - run the ssh key import step first.'
        return 1
    fi
    # the key is not named id_*, so ssh will not offer it by itself
    export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/default -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    if [[ -d "$HOME/.local/share/yadm/repo.git" ]]; then
        Note 'dotfiles repo already cloned.'
    else
        run yadm clone git@github.com:martona/dotfiles.git || true
    fi
    run yadm gitconfig core.sshCommand "ssh -i $HOME/.ssh/default -o IdentitiesOnly=yes"
    run yadm fetch origin
    run yadm reset --hard origin/master
    run yadm status
    unset GIT_SSH_COMMAND
    Done 'dotfiles in place (distro defaults clobbered).'
}

# 10) pkg0, then the standard tools through it - cosign first, the rest
#     verify against it.
step_pkg0 () {
    Step 'Installing pkg0 and the standard tool set...'
    runsh "curl -fsSL https://github.com/martona/pkg0/releases/latest/download/install.sh | bash"
    run sudo pkg0 install sigstore/cosign
    run sudo pkg0 install martona/clipp
    run sudo pkg0 install martona/yo
    run sudo pkg0 install topgrade-rs/topgrade
    Done 'pkg0 + cosign, clipp, yo, topgrade installed.'
}

# 11) clevis TPM2 bind for the LUKS keystore; optionally rotate the
#     keystore passphrase afterwards. Both passphrase prompts are theirs,
#     not ours, but they must be pointed at /dev/tty: under curl | bash
#     stdin is the script itself, and clevis's plain read would silently
#     eat the rest of it as the "passphrase".
step_clevis () {
    Step 'Binding the LUKS keystore to the TPM (clevis)...'
    # match the box's initrd generator: dracut (default from Ubuntu 26.04)
    # gets clevis-dracut, an initramfs-tools box gets clevis-initramfs -
    # the wrong one is missing or drags in the other generator
    local initpkg=clevis-dracut
    if ! command -v dracut >/dev/null \
       && dpkg-query -W -f'${Status}' initramfs-tools 2>/dev/null | grep -q 'install ok installed'; then
        initpkg=clevis-initramfs
    fi
    run sudo apt -y install clevis clevis-tpm2 clevis-luks "$initpkg" tpm2-tools
    local dev
    ask dev 'LUKS device [/dev/zd0]: '
    dev="${dev:-/dev/zd0}"
    if [[ ! -e "$dev" ]]; then Warn "$dev does not exist - skipping."; return 1; fi
    if sudo clevis luks list -d "$dev" 2>/dev/null | grep -q tpm2; then
        Note "$dev already has a tpm2 binding."
    else
        Note 'clevis will ask for the existing LUKS passphrase.'
        run sudo clevis luks bind -d "$dev" tpm2 '{"pcr_bank":"sha256","pcr_ids":"0,2,4,7,14"}' </dev/tty
    fi
    local yn
    ask yn 'also rotate the keystore passphrase (cryptsetup luksChangeKey)? [y/N]: '
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        if [[ -e /dev/zvol/rpool/keystore ]]; then
            run sudo cryptsetup luksChangeKey /dev/zvol/rpool/keystore </dev/tty
        else
            Warn '/dev/zvol/rpool/keystore does not exist - skipping the rotate.'
        fi
    fi
    run sudo clevis luks list -d "$dev"
    Done 'clevis binding in place.'
}

# 12) force-load all ZFS encryption keys before zfs-mount at boot.
step_zfskeys () {
    Step 'Installing the ZFS key autoload unit...'
    if ! command -v zfs >/dev/null; then
        Warn 'zfs is not installed here - skipping.'
        return 0
    fi
    write_root_file /etc/systemd/system/99-zfs-load-key.service <<'EOF'
[Unit]
Description=Force ZFS Key Load
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/sbin/zfs load-key -a

[Install]
WantedBy=zfs.target
EOF
    run sudo systemctl daemon-reload
    run sudo systemctl enable --now 99-zfs-load-key.service
    Done 'ZFS keys autoload at boot.'
}

# 13) CPU governor at boot: schedutil where the driver offers it (ramps
#     under load, minimal otherwise), else powersave - which only remains
#     on intel_pstate/amd-pstate active mode, where powersave IS the
#     dynamic governor. Never pick powersave on acpi-cpufreq: there it
#     pins every core to minimum frequency. Writes sysfs directly, so no
#     cpupower/linux-tools dependency; $$ is systemd's escape for $.
step_governor () {
    Step 'Installing the CPU governor unit (schedutil, else powersave)...'
    write_root_file /etc/systemd/system/99-powersave-governor.service <<'EOF'
[Unit]
Description=Set CPU governor to schedutil (or powersave)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'g=schedutil; grep -qw schedutil /sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors 2>/dev/null || g=powersave; for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -e "$$f" ] && echo "$$g" > "$$f"; done; exit 0'

[Install]
WantedBy=multi-user.target
EOF
    run sudo systemctl daemon-reload
    # enable + restart, not enable --now: on a re-run the oneshot is
    # already active (RemainAfterExit), and starting an active unit is a
    # no-op - restart actually re-executes ExecStart
    run sudo systemctl enable 99-powersave-governor.service
    run sudo systemctl restart 99-powersave-governor.service
    runsh "cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo 'no cpufreq here (vm?)'"
    Done 'Governor unit installed and started.'
}

# 14) volatile journals - saves ~4-5GB/day of rootfs writes.
step_journals () {
    Step 'Switching systemd journals to volatile (RAM only)...'
    run sudo mkdir -p /etc/systemd/journald.conf.d
    write_root_file /etc/systemd/journald.conf.d/99-volatile-journals.conf <<'EOF'
[Journal]
Storage=volatile
EOF
    run sudo systemctl restart systemd-journald
    runsh "journalctl --disk-usage || true"
    Done 'Journals are volatile - nothing persists across reboots.'
}

# 15) set the time zone to US Eastern (same default as the Windows script).
step_timezone () {
    Step 'Setting the time zone to US Eastern...'
    local cur
    cur=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ "$cur" == America/New_York ]]; then
        Note "Already 'America/New_York' - nothing to do."
    else
        run sudo timedatectl set-timezone America/New_York
        Done "Time zone: '${cur:-unknown}' -> 'America/New_York'."
    fi
}

# 16) no swap - now and across reboots. The Linux sibling of the Windows
#     pagefile step: swapoff, comment the fstab entries, delete the stock
#     Ubuntu swapfile to get the disk back.
step_swapoff () {
    Step 'Disabling swap (now and across reboots)...'
    # not swapoff -a: that also walks fstab, errors on a dangling entry
    # (swapfile already deleted), and set -e would kill the step. Only
    # turn off what is actually swapped in.
    runsh 'swapon --noheadings --show=NAME | xargs -r sudo swapoff'
    if grep -qE '^[[:space:]]*[^#[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+swap[[:space:]]' /etc/fstab; then
        runsh "sudo sed -i -E 's|^[[:space:]]*[^#[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+swap[[:space:]].*|# &|' /etc/fstab"
        Note 'Commented the swap entries in /etc/fstab.'
    else
        Note 'No swap entries to comment in /etc/fstab.'
    fi
    if [[ -f /swap.img ]]; then
        run sudo rm -f /swap.img
        Note 'Removed the stock /swap.img.'
    fi
    run sudo systemctl daemon-reload
    Done 'Swap is off and stays off.'
}

# ---- cheap state probes ----------------------------------------------------
# Echo done/todo, or nothing when it can't be told from here. Read-only,
# they run on every menu redraw.
probe () {
    case "$1" in
        step_sudo_nopasswd)
            # live test; -k makes sudo ignore (not clear) the 15-minute
            # credential cache, so this only passes on real NOPASSWD
            sudo -k -n true 2>/dev/null && echo done || echo todo ;;
        step_packages)
            local p
            for p in "${PKGS[@]}"; do
                dpkg-query -W -f'${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || { echo todo; return; }
            done
            echo done ;;
        step_authkeys)
            grep -qs 'gh:martona' "$HOME/.ssh/authorized_keys" && echo done || echo todo ;;
        step_grub)
            if grep -qs '^GRUB_TIMEOUT_STYLE=menu' /etc/default/grub \
               && grep -qs '^GRUB_TIMEOUT=5' /etc/default/grub \
               && grep -qs '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub; then echo done; else echo todo; fi ;;
        step_ecc)
            [[ -e /sys/devices/system/edac/mc/mc0 ]] && echo done || echo todo ;;
        step_tcp)
            # judge by live kernel values, not our conf file - the tuning
            # may have arrived by other means
            local cc rmax wmax rbuf wbuf
            cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
            rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
            wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)
            rbuf=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
            wbuf=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
            if [[ "$cc" == bbr && "${rmax:-0}" -ge 67108864 && "${wmax:-0}" -ge 67108864 \
                  && "${rbuf:-0}" -ge 67108864 && "${wbuf:-0}" -ge 67108864 ]]; then echo done; else echo todo; fi ;;
        step_atuin)
            if command -v atuin >/dev/null || [[ -x "$HOME/.atuin/bin/atuin" ]]; then echo done; else echo todo; fi ;;
        step_sshkey)
            [[ -f "$HOME/.ssh/default" ]] && echo done || echo todo ;;
        step_yadm)
            [[ -d "$HOME/.local/share/yadm/repo.git" ]] && echo done || echo todo ;;
        step_pkg0)
            # pkg0 on the path is the signal; the tools it installs may
            # live outside this user's PATH
            command -v pkg0 >/dev/null && echo done || echo todo ;;
        step_clevis)
            # needs root to inspect LUKS headers; only answer when
            # passwordless sudo is up. Any clevis binding on any LUKS
            # device counts as done.
            sudo -n true 2>/dev/null || { echo ''; return; }
            local d devs
            devs=$(lsblk -prno PATH,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print $1}')
            [[ -z "$devs" ]] && { echo ''; return; }
            for d in $devs; do
                if [[ -n "$(sudo -n clevis luks list -d "$d" 2>/dev/null)" ]]; then echo done; return; fi
            done
            echo todo ;;
        step_zfskeys)
            command -v zfs >/dev/null || { echo ''; return; }
            systemctl is-enabled 99-zfs-load-key.service >/dev/null 2>&1 && echo done || echo todo ;;
        step_governor)
            # enabled is not enough: an older unit preferred powersave even
            # on acpi-cpufreq (pinned to min freq). Judge by the live
            # governor vs what the current logic would pick.
            systemctl is-enabled 99-powersave-governor.service >/dev/null 2>&1 || { echo todo; return; }
            local pol=/sys/devices/system/cpu/cpufreq/policy0 want
            [[ -e "$pol/scaling_governor" ]] || { echo done; return; }  # no cpufreq (vm) - unit is harmless
            want=schedutil
            grep -qw schedutil "$pol/scaling_available_governors" 2>/dev/null || want=powersave
            [[ "$(cat "$pol/scaling_governor" 2>/dev/null)" == "$want" ]] && echo done || echo todo ;;
        step_journals)
            [[ -f /etc/systemd/journald.conf.d/99-volatile-journals.conf ]] && echo done || echo todo ;;
        step_timezone)
            [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" == America/New_York ]] && echo done || echo todo ;;
        step_swapoff)
            # done = nothing swapped in now, and no fstab entry that could
            # bring swap back at boot: uncommented, type swap, and a source
            # that still exists (a dangling /swap.img line can't fire)
            local src armed=""
            while read -r src; do
                case "$src" in
                    UUID=*)     src="/dev/disk/by-uuid/${src#UUID=}" ;;
                    LABEL=*)    src="/dev/disk/by-label/${src#LABEL=}" ;;
                    PARTUUID=*) src="/dev/disk/by-partuuid/${src#PARTUUID=}" ;;
                esac
                [[ -e "$src" ]] && armed=1
            done < <(awk '$1 !~ /^#/ && $3 == "swap" {print $1}' /etc/fstab 2>/dev/null)
            if [[ -z "$armed" && -z "$(swapon --noheadings --show 2>/dev/null)" ]]; then echo done; else echo todo; fi ;;
        *) echo '' ;;
    esac
}

# ---- catalog ---------------------------------------------------------------
# key | function | title | tag ('' / interactive / check)
STEPS=(
    ' 1|step_sudo_nopasswd|Passwordless sudo (sudoers.d, visudo-validated)|'
    ' 2|step_packages|apt update + upgrade + standard packages|'
    ' 3|step_authkeys|authorized_keys from GitHub (martona)|'
    ' 4|step_grub|Saner grub (menu, 5s timeout, recordfail cap)|'
    ' 5|step_ecc|Check ECC / EDAC state and errors|check'
    ' 6|step_tcp|TCP tuning (64MB buffers, BBR)|'
    ' 7|step_atuin|Install atuin (no login/sync)|interactive'
    ' 8|step_sshkey|Import ~/.ssh/default from another box (scp)|interactive'
    ' 9|step_yadm|yadm + neovim + dotfiles (clobbers defaults)|interactive'
    '10|step_pkg0|pkg0 + cosign, clipp, yo, topgrade|'
    '11|step_clevis|clevis: bind LUKS keystore to TPM2|interactive'
    '12|step_zfskeys|ZFS: autoload encryption keys at boot|'
    '13|step_governor|CPU governor: schedutil (or powersave)|'
    '14|step_journals|Volatile journals (RAM only, saves rootfs writes)|'
    '15|step_timezone|Set the time zone to US Eastern|'
    '16|step_swapoff|Disable swap (swapoff, fstab, removes /swap.img)|'
)

invoke_step () {
    echo
    # subshell so one failing step never kills the menu; set -e inside so
    # a step stops at its first unhandled error
    ( set -e; "$1" )
    local rc=$?
    [[ $rc -ne 0 ]] && Fail "step failed (exit $rc) - see above."
    return 0
}

# ---- run -------------------------------------------------------------------
if [[ -n "$ALL" ]]; then
    Section 'Provisioning - running all non-interactive steps'
    for s in "${STEPS[@]}"; do
        IFS='|' read -r _key fn _title tag <<<"$s"
        if [[ "$tag" == interactive ]]; then
            echo
            Note "Skipping $fn (interactive only - run it from the menu)."
            continue
        fi
        invoke_step "$fn"
    done
    echo
    Done 'All non-interactive steps complete.'
    exit 0
fi

while true; do
    echo
    printf '  %sprovision%s - linux box setup steps%s\n' "$C_GRN" "$C_GRY" "$C_OFF"
    printf '  %s-----------------------------------------------%s\n' "$C_GRY" "$C_OFF"
    for s in "${STEPS[@]}"; do
        IFS='|' read -r key fn title tag <<<"$s"
        state=$(probe "$fn")
        printf '  %s[%s]%s ' "$C_CYN" "$key" "$C_OFF"
        if [[ "$tag" == check ]]; then
            # read-only test: green ok / red FAIL, like the Windows script
            if   [[ "$state" == done ]]; then printf '%sok    %s' "$C_BGRN" "$C_OFF"
            elif [[ "$state" == todo ]]; then printf '%sFAIL  %s' "$C_RED"  "$C_OFF"
            else                              printf '      '; fi
        else
            if   [[ "$state" == done ]]; then printf '%sdone  %s' "$C_GRN" "$C_OFF"
            elif [[ "$state" == todo ]]; then printf '%stodo  %s' "$C_YEL" "$C_OFF"
            else                              printf '      '; fi
        fi
        if [[ "$state" == done && "$tag" != check ]]; then
            printf '%s%s%s' "$C_GRY" "$title" "$C_OFF"
        else
            printf '%s%s%s' "$C_WHT" "$title" "$C_OFF"
        fi
        if   [[ "$tag" == interactive ]]; then printf '  %s(interactive)%s' "$C_GRY" "$C_OFF"
        elif [[ "$tag" == check ]];       then printf '  %s(read-only)%s'   "$C_GRY" "$C_OFF"; fi
        echo
    done
    printf '  %s[ a]%s       run all\n' "$C_CYN" "$C_OFF"
    printf '  %s[ q]%s       quit\n'    "$C_CYN" "$C_OFF"
    echo

    read -r -p '  run which? ' choice </dev/tty
    choice="${choice// /}"
    case "$choice" in
        # exit, not break: under curl | bash the script IS stdin, and after
        # the loop bash would go back to the pipe for more script before
        # quitting - which can block instead of seeing EOF. End the process
        # right here.
        q|quit|exit) echo; Done 'Bye.'; exit 0 ;;
        a|all)
            for s in "${STEPS[@]}"; do
                IFS='|' read -r _key fn _title _tag <<<"$s"
                invoke_step "$fn"
            done
            echo
            read -r -p '  Enter to return to the menu' _ </dev/tty
            continue ;;
    esac

    found=""
    for s in "${STEPS[@]}"; do
        IFS='|' read -r key fn _title _tag <<<"$s"
        if [[ "${key// /}" == "$choice" ]]; then found="$fn"; break; fi
    done
    if [[ -z "$found" ]]; then Warn "No such option '$choice'."; continue; fi

    invoke_step "$found"
    echo
    read -r -p '  Enter to return to the menu' _ </dev/tty
done
