# airgap-gpu

> Offline bundle builder for the NVIDIA data-center GPU stack on air-gapped
> RHEL, Rocky, AlmaLinux and Ubuntu hosts.
>
> Air-gapped CUDA, cuDNN, NCCL, DCGM, Fabric Manager and DOCA/OFED installs
> for dark-site and classified datacenter environments.

Builds a self-contained tarball — driver, CUDA, cuDNN, NCCL, DCGM, Fabric
Manager, Container Toolkit, DOCA/OFED — on an online host, and installs it on a
machine that has never seen a network.

No vendor binaries are redistributed. Packages are fetched from NVIDIA's own
repositories under your entitlement.

> **Status: 0.1.0, early release.** The resolution rules documented below come
> from production air-gapped deployments. This modular codebase is a fresh
> implementation of those rules and is still being re-verified platform by
> platform; the table under [Supported platforms](#supported-platforms)
> reflects the rules' field history, not a completed test pass of this
> release. Run it on a non-critical build host first and please report
> anything that breaks.

---

## Table of contents

- [Why this is hard](#why-this-is-hard)
- [Quick start](#quick-start)
- [Supported platforms](#supported-platforms)
- [Free and Pro](#free-and-pro)
- [Known failures and why they happen](#known-failures-and-why-they-happen)
- [Redistribution](#redistribution)

---

## Why this is hard

Every package manager is built on an assumption that air-gapped deployment
breaks: that if resolution goes wrong, you can fix it in place.

On an air-gapped target you cannot. The bundle is carried across a boundary,
the install fails, and there is no network to recover with. Whatever is wrong
has to be fixed back on the build host, and the bundle has to go through the
transfer approval again.

So the real problem is not "download packages offline." It is making the
resolution correct on the build host, where the target's own repository view
does not exist yet.

NVIDIA's support matrix describes what is nominally compatible. It does not
describe what `dnf` and `apt` actually install. Everything in
[Known failures](#known-failures-and-why-they-happen) is a gap between those
two documents.

---

## Quick start

```bash
sudo bash airgap-gpu.sh
```

An interactive checklist selects components and versions. The builder then
collects packages, generates an offline installer, and writes a tarball.

Non-interactive, all defaults:

```bash
sudo AIRGAP_GPU_NONINTERACTIVE=1 bash airgap-gpu.sh
```

On the air-gapped target:

```bash
tar -xzf <os>_bundle.tar.gz
cd <os>_bundle
sudo bash install_offline.sh
sudo reboot
sudo bash all_check.sh
```

**The build host must run the same OS and version as the target.** Downloaded
`.deb` and `.rpm` packages are distribution-version specific.

### Build flags

| Flag | Effect |
|------|--------|
| `AIRGAP_GPU_NONINTERACTIVE=1` | Skip the checklist, build the default stack |
| `KERNEL=<uname -r>` | Bundle `kernel-devel` for the target's kernel |
| `CUDA_FULL_TOOLKIT=1` | Full CUDA toolkit meta instead of the slim set |

---

## Supported platforms

| Family | Version | Status |
|--------|---------|--------|
| RHEL | 9.x | verified |
| Rocky Linux | 9.x | verified |
| Ubuntu | 24.04 | verified |
| Ubuntu | 22.04 | verified |
| Ubuntu | 26.04 | supported, not yet verified |
| AlmaLinux | 9.x | supported, not yet verified |
| CentOS Stream | 9 | supported, not yet verified |

Verified means the full stack was built, installed and brought up on that
platform. The remaining three are accepted by the OS gate and share a
resolution path with a verified sibling, but have not been run end to end.

Tested against Blackwell B200/B300 SXM, Hopper H100/H200, and Ada L40S/A40
class accelerators.

---

## Free and Pro

The free build handles the GPU driver completely — including the variant
resolution that most hand-rolled scripts get wrong. It is not a crippled demo;
it produces a working driver bundle.

| | Free | Pro |
|---|---|---|
| Driver collection and install | yes | yes |
| Ubuntu variant resolution | yes | yes |
| Single-OS bundle | yes | yes |
| CUDA Toolkit | — | yes |
| cuDNN | — | yes |
| NCCL | — | yes |
| DCGM | — | yes |
| Fabric Manager + NVLink stack | — | yes |
| DOCA / OFED | — | yes |
| Cross-component version pinning | — | yes |
| Driver branch isolation | — | yes |
| OS minor-version leak prevention | — | yes |
| Target-kernel bundling | — | yes |
| Offline dependency-closure check | — | yes |
| Pre-bundle verification gates | — | yes |
| Verified compatibility matrix | — | yes |
| Quarterly re-verification | — | yes |

Pro is an annual subscription. **The version you have keeps working after it
lapses** — you stop receiving updates, not the software.

The subscription is not really for the code. Driver branches are reissued on a
quarterly cadence and each one breaks in a new way; what you are paying for is
somebody finding out before you do.

| Tier | Price | Build machines |
|---|---|---|
| Solo | $290 / year | 1 |
| Team | $1,490 / year | 5 |
| Partner | $4,900 / year | not capped in practice; deployment at customer sites allowed |

Licensing is per build machine. Air-gapped target nodes are unlimited and never
counted.

→ [Get airgap-gpu Pro](https://buy.polar.sh/polar_cl_smaNqg9lscvYP52MzxtY0ZHzCiuyIHKbBRIBx3N3Vmg)

After purchase, activate the key once on the build machine:

```bash
sudo bash airgap-gpu.sh --activate <license-key>
```

---

## Known failures and why they happen

These are real failures from production air-gapped deployments. Each one is
handled by the builder; they are documented here because knowing the cause is
useful whether or not you use this tool.

### `cuda-drivers-580 : Depends: nvidia-driver-580 ... not installable`

The `cuda-drivers-<major>` metapackage declares:

```
Depends: nvidia-driver-<major> | -open | -server | -server-open
```

All four alternatives are top-level metas living in, or transitioning through,
the Ubuntu archive. On R580 LTSB none is installable at a pinned version, so
apt reports held broken packages and the download yields nothing.

The metapackage also defaults to the **desktop** branch, which is the root
cause of most data-center driver update conflicts.

**Fix:** drop the meta. Install the concrete children directly —
`nvidia-dkms-<major>[-open]`, `nvidia-kernel-source-<major>[-open]`,
`nvidia-driver-cuda-<major>`, `nvidia-kernel-common-<major>`,
`libnvidia-compute-<major>`, `libnvidia-cfg1-<major>`, `nvidia-utils-<major>`,
`libnvidia-gl-<major>`.

### `libnvidia-gl-580-server : but it is not going to be installed`

The most misunderstood part of NVIDIA's Ubuntu packaging.

**The `-open` suffix applies only to kernel module packages.** Userspace
children are shared and carry only `-server`.

`nvidia-driver-580-server-open` depends on:

```
nvidia-dkms-580-server-open            ← kernel module,  -server-open
nvidia-kernel-source-580-server-open   ← kernel module,  -server-open
libnvidia-gl-580-server                ← userspace,      -server only
libnvidia-compute-580-server           ← userspace,      -server only
nvidia-kernel-common-580-server        ← userspace,      -server only
nvidia-utils-580-server                ← userspace,      -server only
```

Filtering children by exact suffix match drops every userspace package. The
bundle builds cleanly online and fails on the target.

**Fix:** accept the shared `-server` userspace of the same family. Exclude only
the mutually exclusive kernel-module counterpart.

### `nvidia-open-dkms` not found on RHEL 9

That package does not exist. Current naming:

| Role | Package |
|------|---------|
| Open driver meta | `nvidia-open` (noarch, version-locked) |
| Open kernel module | `kmod-nvidia-open-dkms` |
| Closed kernel module | `kmod-nvidia-latest-dkms` |
| Proprietary entry points | `cuda-drivers`, `nvidia-driver` |

`nvidia-open-<major>` are legacy per-branch metas from the R560/R565 era. On
recent branches the bare `nvidia-open` carries the version instead.

Blackwell B200/B300 require the open kernel module: `nvidia-open` +
`kmod-nvidia-open-dkms`. Bundle `nvidia-kmod-common` explicitly — both DKMS
kmods require it and offline resolution will not pull it implicitly.

### `kmod-nvidia-open-dkms` filtered out by modular filtering

The CUDA repository ships `nvidia-driver` as a DNF module. With a default
stream enabled, dnf filters out both DKMS kmods and the driver install fails
with no obvious cause.

**Fix:**

```bash
sudo dnf module reset nvidia-driver -y
```

Run it on the build host and again on the target before install.

### `datacenter-gpu-manager-4-core (= 1:4.5.3-1) but 1:4.6.0-1 is to be installed`

The DCGM 4.x meta hard-depends on an exact version of its `-core` sibling.
Pinning only the meta lets apt resolve `-core` at its newest.

**Fix:** pin the whole family at the same version.

```
datacenter-gpu-manager-4-core
datacenter-gpu-manager-4-proprietary
datacenter-gpu-manager-4-config
datacenter-gpu-manager-4-devel
```

While you are here, two more DCGM rules:

- DCGM 3.3.x (`datacenter-gpu-manager`) works with R535 and earlier only.
  DCGM 4.x (`datacenter-gpu-manager-4-cuda{12,13}`) requires R545+. Crossing
  that line fails on NVML initialization or missing symbols.
- The `-cudaN` suffix tracks the **CUDA user-mode driver** major, not the
  toolkit major you selected. They usually coincide and sometimes do not, and
  repositories often ship only one of `-cuda12` / `-cuda13`. Probe both before
  concluding DCGM is unavailable.

### `doca-ofed` held broken packages on Ubuntu

`doca-ofed` is a meta with roughly fifty hard dependencies. Downloading it
alone produces a 2 KB stub that cannot install, because the entire transitive
tree is missing.

**Fix:** resolve the full recursive `Depends` graph and download every entry,
excluding Recommends and Suggests. Fewer than about twenty `.deb` files
collected means resolution failed.

Note the repository layout changed with DOCA-Host 2.x:

| | Path |
|---|---|
| DOCA-Host, RHEL | `.../repo/doca/<ver>/rhel<X.Y>/x86_64/` |
| DOCA-Host, Ubuntu | `.../repo/doca/<ver>/ubuntu<22.04>/x86_64/` (dotted) |
| Legacy MLNX_OFED | `.../repo/mlnx_ofed/<ver>/ubuntu<2204>/` (dotless) |

The DOCA path serves a flat repository with no pre-baked `.repo` or `.list`
file. The signing key moved to
`https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub`; the legacy
URL still resolves but modern DOCA repos are signed only with the new key.

### `xpmem-dkms` requires `/bin/sh`

A DOCA dependency needs a package from the base repositories, so
`--disablerepo='*'` cannot be used for the DOCA transaction.

Related: DOCA's transitive dependencies will pull a new kernel. Pin the running
one with `grubby --set-default` and add `--exclude='kernel*'`.

### The target booted `el9_8` after installing an `el9_7` bundle

The highest-impact failure in this stack, because the symptom appears far from
the cause.

A build host on `el9_7` has repositories that also serve `el9_8` errata.
`dnf download --resolve --alldeps` resolves transitive dependencies to those
newer packages, so the bundle physically contains `el9_8` glibc, systemd,
python3 and kernel-headers.

At install time `--releasever` has no effect on a `file://` repository and
`--setopt=exclude` is unreliable. One `el9_8` glibc pulls `el9_8`
kernel-headers, which pulls `kernel-core`, and the target boots a 9.8 kernel.
OFED kernel modules built for 9.7 then fail to load and `openibd` will not
start.

**Fix:** after download, delete every package whose release tag carries a minor
newer than the build host's. NVIDIA and CUDA packages use a plain `el9` tag and
the target's own ISO supplies its matching minor, so the sweep is safe and
name-agnostic. Apply it to the DOCA package directory as well — its transitive
dependencies are not subject to `--releasever` filtering at all.

### `dnf download` produced 0 RPMs on Rocky Linux

`--releasever` semantics differ by distribution.

| Distribution | `--releasever` | Reason |
|--------------|----------------|--------|
| RHEL | minor (`9.7`) | EUS minor paths exist on the CDN |
| Rocky / Alma | major (`9`) | mirrors serve only `…/9/BaseOS/` |

Passing a minor version on Rocky 404s BaseOS, AppStream and Extras. dnf drops
them, the gcc / make / glibc / dkms dependencies vanish, and the build produces
nothing.

### The wrong driver branch was installed

Dependency resolution crosses driver branches unless explicitly blocked.

On Ubuntu, driver metas declare OR-alternatives:

```
Depends: libnvidia-compute-550-server (>= 550.163.01)
       | libnvidia-compute-560-server
       | libnvidia-compute-570-server
       | libnvidia-compute-580-server
```

apt satisfies whichever resolves easiest, typically the newest. Pinning your
intended branch does not help — nothing told apt the others were unacceptable.

Separately, the Ubuntu archive publishes older-branch metapackages as
**transitional stubs** that forward-upgrade to the current LTSB. Installing
R550 from `archive.ubuntu.com` yields R580 binaries despite the package name,
and the stub declares a hard dependency rather than an alternative, so pins
cannot save you.

**Fix:** resolve driver versions from the NVIDIA CUDA repository only,
identified through the origin column of `apt-cache madison`. Then pin every
`nvidia-*` / `libnvidia-*` / `xserver-xorg-video-nvidia-*` package carrying a
different major at priority `-1`.

On RHEL the package name is constant across branches and the branch lives in
the version, so enumerate available NEVRAs and `--exclude` each one whose major
differs. Rocky local repositories in particular accumulate RPMs from several
branches.

### cuDNN installed a version nobody selected

`cudnn9-cuda-<major>` always depends on the newest CUDA series sub-package. On
a pinned CUDA build it drags the toolkit forward, and the chain
`cudnn9-cuda-12` → `cudnn9-cuda-12-9` → `libcudnn9-cuda-12` resolves each hop
at latest. The installed header then reports a version you never asked for.

**Fix:** skip the meta. Collect the sub-packages directly at the pinned
version — `libcudnn9-cuda-<major>`, `-dev-`, `-headers-`, `-static-`.

### DKMS failed on the target: no matching `kernel-devel`

The bundle installs a driver against the target's running kernel and must never
change it. Exclude and purge:

```
kernel, kernel-core, kernel-modules, kernel-modules-core,
kernel-modules-extra, kernel-devel-matched, kernel-uki-virt
```

`kernel-devel-matched` is a meta that always tracks the repository's newest
kernel — the usual vector for an unintended kernel bump.

**Do not exclude `kernel-headers`.** It sits on a hard dependency chain
(`kmod-nvidia-open-dkms` → `dkms` → `gcc` → `glibc-devel` → `kernel-headers`)
and excluding it fails the entire resolve. It ships compile-time headers only
and cannot change the booted kernel.

Also purge precompiled kmods named `kmod-nvidia-<driver>-<kernel>-...`. They
hard-require one specific kernel and fail on a target running anything else.
Keep the DKMS-source kmods.

When the target runs a kernel other than the ISO's GA kernel, its
`kernel-devel` exists neither on the ISO nor in a build-host-derived bundle:

```bash
sudo KERNEL=5.14.0-687.10.1.el9_8.x86_64 bash airgap-gpu.sh
```

The build host's own kernel version is irrelevant. What matters is whether any
reachable repository can serve that kernel's devel package — search the pinned
releasever, the major releasever, and configured-but-disabled repos, since
older errata rotate out of the standard repositories.

### The build exited silently right after configuring repositories

Under `set -euo pipefail`, an unguarded `curl … | gpg` pipe is fatal. A
transient failure fetching the signing key aborts the whole builder with no
error, immediately after the last log line.

**Fix:** install the key via `cuda-keyring_1.1-1_all.deb` first and fall back
to the `.pub` dearmor only if that fails, with `set +e` around both.

Two related traps:

- `dpkg -i` of an already-installed, same-version `cuda-keyring` will **not**
  recreate a deleted conffile. The repo silently stays unregistered and
  `apt-get update` reports zero errors. Purge before reinstalling.
- `ls a*.list a*.sources` returns non-zero if *either* glob misses, even when
  the other matched. Test each glob independently with `compgen -G`.

---

## Redistribution

This project redistributes no NVIDIA, Mellanox or Dell binaries. Packages are
fetched from vendor repositories by the operator, under the operator's own
entitlement.

vGPU Manager is licensed software distributed through the NVIDIA Licensing
Portal and is not available from any public repository. The builder stages a
directory for it and never downloads it.

---

## License

The free edition in this repository (`airgap-gpu.sh` and `lib/`) is released
under the MIT License; see [LICENSE](LICENSE).

The Pro modules are commercial software, delivered to subscribers, and are not
part of this repository.

NVIDIA, CUDA and related names are trademarks of NVIDIA Corporation. This
project is not affiliated with or endorsed by NVIDIA.

---

## Contributing

Issues describing a resolution failure are welcome, especially with the verbatim
error output and your `/etc/os-release`. Those are what this document is made
of.
