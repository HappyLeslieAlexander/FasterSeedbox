# FasterSeedbox

Kernel and network tuning scripts aimed at sustained high-throughput torrent workloads. One script for modern Debian/Ubuntu, one for FreeBSD. The parameters are modeled on [jerry048/Dedicated-Seedbox](https://github.com/jerry048/Dedicated-Seedbox); the packaging, idempotency, and dry-run tooling are this project's own.

## What it does

- Enables **BBR + fq** on Linux, or the **RACK/BBR TCP stack** on FreeBSD, with **HTCP** as a fallback when BBR is unavailable.
- Sizes TCP buffers, `tcp_mem`, `rmem_max`, `wmem_max` in five tiers based on physical RAM (512 MB / 1 GB / 4 GB / 16 GB / larger).
- Raises file descriptor limits to 1 048 576 for PAM sessions, root, and systemd-managed services.
- Selects per-device I/O schedulers: `kyber` for SSD/NVMe, `mq-deadline` for rotational drives.
- Applies NIC ring-buffer and tx-queue targets, clamped to the hardware maximum so low-end virtual NICs don't fail.
- Disables virtio/vmxnet3 offloads (TSO/GSO/GRO) when the host is virtualized; leaves them alone on bare metal.
- Sets `initcwnd` / `initrwnd` to 25 on the default route.
- Installs a small boot service that re-applies every setting the kernel or driver forgets across reboots.

## Requirements

**Linux:** Debian 12+ or Ubuntu 22.04+ with a kernel that has BBR built in (6.1+). Must have `apt-get`. Root required.

**FreeBSD:** 13.x or 14.x. On 14.1+ BBR/RACK work out of the box; on 14.0 or older you need a custom kernel built with `WITH_EXTRA_TCP_STACKS=1` (the script prints the build recipe if BBR isn't loadable). Root required.

## Quick start

**Linux:**
```sh
curl -fsSL https://cdn.jsdelivr.net/gh/HappyLeslieAlexander/FasterSeedbox/debian.sh | sudo sh
```

**FreeBSD:**
```sh
fetch -qo - https://cdn.jsdelivr.net/gh/HappyLeslieAlexander/FasterSeedbox/freebsd.sh | sudo sh
```

To preview the changes without touching the system, download the script and run it with `--dry-run`:

```sh
curl -fsSLO https://cdn.jsdelivr.net/gh/HappyLeslieAlexander/FasterSeedbox/debian.sh
sudo sh debian.sh --dry-run
```

## Options

### linux.sh

| Flag | Effect |
|---|---|
| `--dry-run` | Print every file that would be written, but don't modify anything. |
| `--help` | Show usage and exit. |

### freebsd.sh

| Flag | Effect |
|---|---|
| `--dry-run` | Print every file that would be written, but don't modify anything. |
| `--offload=virt` | Disable TSO/LRO/VLAN-HWTSO only under a hypervisor (default). |
| `--offload=always` | Disable offloads unconditionally — useful for boxes running `pf` / `bpf` / packet capture at line rate. |
| `--offload=never` | Leave offloads alone — right for physical 10 GbE NICs where LRO hurts to turn off. |
| `--help` | Show usage and exit. |

## Files installed

### Linux

```
/etc/sysctl.d/99-seedbox.conf               # all sysctl values
/etc/security/limits.d/99-seedbox.conf      # nofile for PAM sessions
/etc/systemd/system.conf.d/99-seedbox.conf  # DefaultLimitNOFILE
/etc/modules-load.d/seedbox-bbr.conf        # sch_fq, tcp_bbr
/usr/local/sbin/seedbox-runtime.sh          # runtime helper
/etc/systemd/system/seedbox-tune.service    # boot-time re-apply
```

Nothing is written to `/etc/sysctl.conf` or `/etc/security/limits.conf`. If those files contain entries from a previous installer, the script will warn you.

### FreeBSD

```
/boot/loader.conf.d/seedbox.conf          # loader tunables (reboot required)
/etc/sysctl.conf                          # runtime sysctls
/etc/login.conf                           # 'seedbox' login class appended
/etc/rc.conf                              # sysrc edits (kld_list, powerd, ifconfig)
/usr/local/etc/rc.d/seedbox_tune          # boot-time re-apply
```

Every modified file is backed up with a `.bak-YYYYMMDD-HHMMSS` suffix before the first write.

## Verification

Both scripts read back critical values after writing and print `[+]` or `[x]` lines. A non-zero exit code (`3`) means at least one sanity check failed; re-read the log. On Linux you can double-check manually:

```sh
sysctl net.ipv4.tcp_congestion_control   # expect: bbr
sysctl net.core.default_qdisc            # expect: fq
systemctl is-enabled seedbox-tune        # expect: enabled
```

On FreeBSD:

```sh
sysctl net.inet.tcp.functions_default   # expect: bbr (or htcp fallback)
sysctl kern.ipc.somaxconn               # expect: 524288
service seedbox_tune status             # expect: enabled
```

## FreeBSD: login class assignment

The `seedbox` class grants the high `openfiles` limit but isn't assigned to anyone automatically (FreeBSD has no `*` wildcard in `login.conf`). After install:

```sh
pw usermod <torrent-user> -L seedbox
```

Then log out and back in — PAM reads the class at session start.

## Rollback

Each script prints its own rollback commands at the end of a run. In general:

**Linux:**
```sh
sudo systemctl disable --now seedbox-tune.service
sudo rm -f /etc/sysctl.d/99-seedbox.conf \
           /etc/security/limits.d/99-seedbox.conf \
           /etc/systemd/system.conf.d/99-seedbox.conf \
           /etc/modules-load.d/seedbox-bbr.conf \
           /usr/local/sbin/seedbox-runtime.sh \
           /etc/systemd/system/seedbox-tune.service
sudo systemctl daemon-reload && sudo systemctl daemon-reexec
sudo sysctl --system
sudo reboot
```

**FreeBSD:** replace the four edited files with their `.bak-*` copies, rebuild the login capability database, remove the loader drop-in and rc.d script, then reboot.

## Design notes

- **Drop-ins over file rewrites.** Both installers avoid editing `sysctl.conf` / `limits.conf` in place; fragments go into `*.d/` directories so a later removal doesn't leave the base files mangled.
- **Idempotent re-runs.** Running the script a second time overwrites the same drop-in files and the same backup slot for the current minute. `login.conf` and `rc.conf` edits are guarded by marker checks.
- **Best-effort, not fail-fast.** Tuning is best-effort; a single `ethtool` or `sysctl` rejection shouldn't abort the rest. The scripts use `set -u` (not `-eu`) and absorb individual errors, then report the total count at the end via exit code 3.
- **Runtime vs. persistent split.** Anything the kernel or driver drops at reboot (ring buffers, tx queue length, offloads, IO scheduler, `initcwnd`) lives in a single runtime helper that both the installer and the boot service call. Everything else is a persistent config file.
- **POSIX sh.** Both scripts pass `dash -n` and `shellcheck -s sh` cleanly, so they work on stock `/bin/sh` in Debian, Ubuntu, and FreeBSD base.

## License

[GPL-3.0](./LICENSE)
