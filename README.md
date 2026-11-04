# z-rapl-init

A small Bash/systemd utility that initializes Intel RAPL package power limits **before `thermald` starts**.

On the target Ubuntu laptop, the RAPL package limits reset to 200 W (PL1) and 200 W (PL2) after reboot. `z-rapl-init` writes more reasonable initial values so that `thermald` can subsequently manage CPU power and temperature. It is **not** a replacement for `thermald` or a persistent power-limit controller.

## How it works

At startup, `z-rapl-init`:

1. Checks the Intel RAPL package interfaces and verifies that constraint 0 is `long_term` (PL1) and constraint 1 is `short_term` (PL2).
2. Reads and reports the current limits.
3. Loads and validates its Bash configuration.
4. Unless `--force` is specified, writes new limits **only if both** current values are at least their corresponding initialization thresholds. Otherwise, it exits successfully without modifying either limit.
5. Writes PL1 and PL2 in microwatts and reads them back to verify the result.

The default configuration requests **PL1 = 35 W** and **PL2 = 55 W**, with initialization thresholds of **200 W** for each limit. These values are specific to the tested machine and should not be assumed suitable for other hardware.

The systemd integration orders `z-rapl-init.service` before `thermald.service`. The `thermald` drop-in uses `Wants=` rather than `Requires=`, so failure of the initialization service does not prevent `thermald` from starting (**fail-open**).

After initialization, `thermald` may change PL1. Therefore, observing a value other than 35 W later in the boot is not necessarily a failure.

## Requirements

- Linux with Intel RAPL powercap interfaces at `/sys/class/powercap/intel-rapl:0/`.
- Bash, GNU `getopt`, systemd, and the `install` utility.
- `thermald` installed for the intended startup integration.
- Root privileges for installing the service and writing RAPL limits.

The implementation expects `constraint_0_name=long_term` and `constraint_1_name=short_term`; it will not write limits if this mapping differs.

## Project files

| File | Purpose |
| --- | --- |
| `z-rapl-init` | Main executable |
| `z-rapl-init.conf` | Editable configuration |
| `z-rapl-init.conf.template` | Reference configuration template |
| `install.sh` | Installer |
| `z-rapl-init.service` | systemd service unit |
| `z-rapl-init.service.template` | Reference service template |
| `thermald.conf` | systemd drop-in source for `thermald` |
| `thermald.conf.template` | Reference drop-in template |

The `.template` files are reference copies; the installer uses the corresponding files without `.template`.

## Configuration

The default installed configuration path is:

```text
/etc/default/z-rapl-init.conf
```

Example:

```bash
PL1=35
PL2=55

PL1_INITIAL_THRESHOLD=200
PL2_INITIAL_THRESHOLD=200
```

All values are in **watts** and must be positive integers from **1 to 999**. The script converts them to microwatts when interacting with sysfs.

The configuration is sourced as Bash code. **Only trusted administrators should be able to modify it.** A Bash syntax check does not make an untrusted configuration safe.

## Installation

From the project directory:

```bash
sudo ./install.sh
```

The installer:

- Checks required source files and Bash syntax.
- Installs the executable as `/usr/local/sbin/z-rapl-init` (`755`).
- Installs the configuration as `/etc/default/z-rapl-init.conf` (`644`), preserving an existing configuration unless `--force-config` is specified.
- Installs `/etc/systemd/system/z-rapl-init.service` (`644`).
- Installs the `thermald` drop-in at `/etc/systemd/system/thermald.service.d/10-z-rapl-init.conf` (`644`).
- Runs `systemctl daemon-reload` and enables `z-rapl-init.service` for future boots.

**Installation does not start or restart either service.** The intended initialization takes place on the next boot.

Installer options:

```text
sudo ./install.sh [-f|--force-config] [-c|--config DIR] [-h|--help]
```

- `--force-config`: replace an existing installed configuration.
- `--config DIR`: install the configuration into an existing directory instead of `/etc/default`.
- `--help`: display usage.

**Note:** The installed systemd unit runs the executable without `--config`. Consequently, if you install the configuration outside `/etc/default`, you must also adapt the unit or the executable's configuration lookup before relying on unattended startup.

## Command-line usage

```text
z-rapl-init [-s|--status] [-c|--config DIR] [-f|--force] [-h|--help]
```

| Option | Meaning |
| --- | --- |
| `-s`, `--status` | Display current PL1/PL2 values without loading configuration or writing limits |
| `-c`, `--config DIR` | Read `z-rapl-init.conf` from the specified existing directory |
| `-f`, `--force` | Bypass the initialization threshold check and attempt to apply the configured limits |
| `-h`, `--help` | Display usage |

Examples:

```bash
# Read-only status (typically works without sudo)
z-rapl-init --status

# Test configuration from the development directory
./z-rapl-init --config .

# Apply configured values manually; modifies RAPL limits
sudo z-rapl-init --force
```

`--status` takes precedence over `--force` if both are supplied. Manual `--force` runs while `thermald` is active can race with its power-limit adjustments.

## systemd integration

`z-rapl-init.service` is a `Type=oneshot` unit with:

```ini
[Unit]
Description=Initialize Intel RAPL power limits
ConditionPathExists=/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
Before=thermald.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/z-rapl-init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The `thermald` drop-in adds:

```ini
[Unit]
Wants=z-rapl-init.service
After=z-rapl-init.service
```

This makes `thermald` pull in the initializer and wait for its start job to finish, without requiring that initialization succeed.

## Verification

Check the installed unit and its dependency integration:

```bash
systemctl is-enabled z-rapl-init.service
systemctl cat z-rapl-init.service
systemctl cat thermald.service
sudo systemd-analyze verify \
  /etc/systemd/system/z-rapl-init.service \
  /etc/systemd/system/thermald.service
```

Inspect the installed files:

```bash
ls -l \
  /usr/local/sbin/z-rapl-init \
  /etc/default/z-rapl-init.conf \
  /etc/systemd/system/z-rapl-init.service \
  /etc/systemd/system/thermald.service.d/10-z-rapl-init.conf
```

After a reboot, check execution and current limits:

```bash
systemctl status z-rapl-init.service --no-pager
journalctl -b -u z-rapl-init.service --no-pager
journalctl -b -u thermald.service --no-pager
cat /sys/class/powercap/intel-rapl:0/constraint_[01]_power_limit_uw
```

The sysfs values are in **microwatts**; divide by 1,000,000 to obtain watts. Because `thermald` can subsequently adjust PL1, use the startup journal to assess what `z-rapl-init` attempted and whether it completed successfully.

## Current validation status

- CLI help and read-only status: tested successfully.
- Running with `--config .` against the development configuration: tested successfully; an already-configured system was correctly skipped.
- Installer execution, service enablement, unit/drop-in inspection, and installed file permissions: tested successfully.
- **Automatic initialization after reboot and real RAPL writes by this service: not yet verified.**

## Safety and limitations

- Power limits are hardware-dependent. Do not blindly reuse the example values on another CPU.
- The script targets one specific RAPL package path and constraint mapping; it is not a generic multi-package RAPL manager.
- `--force` writes live power limits. Use it only when you intend to change them.
- Writing PL1 and PL2 is not atomic: an error between writes can leave one value changed.
- Other software, especially `thermald`, may change the limits after initialization.
- This project does not alter CPU governors or frequency policies.
