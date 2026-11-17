#!/usr/bin/env bash
# lib/repo.sh — repository registration and health
#
# Two jobs, and the second one matters more than it looks.
#
# Registration is mechanical. Health is not: a repository that fails to
# refresh is skipped by queries rather than failing them, so the build runs to
# completion and produces a bundle that is quietly missing packages or pinned
# to an older version than the repo actually publishes. That only surfaces on
# the air-gapped target, where there is no network to recover with. So a
# degraded repo state is recorded here and blocks the build later.

REPO_DEGRADED=""          # space-separated names of repos that failed to refresh
REPO_GPG_FAILURE=0        # the failure was a signature error, not a download

# ---------------------------------------------------------------------------
# dnf query wrapper
#
# dnf aborts an entire query when any one enabled repo cannot refresh. A RHEL
# host whose subscription CDN returns 403 for a single repo will return nothing
# for every package query, and a caller that discards stderr concludes "driver
# not found" and prints an empty availability list — with the real cause
# invisible. Queries therefore skip broken repos and keep their stderr.
#
# Downloads deliberately do NOT use this: there a missing repo really is fatal.
# ---------------------------------------------------------------------------
repo_rpm_query() {
    dnf --setopt='*.skip_if_unavailable=1' repoquery "$@" 2>>"${BUILD_LOG:-/dev/null}"
}

repo_prepare() {
    if [ "$PLATFORM_FAMILY" = "rhel" ]; then
        _repo_prepare_rhel
    else
        _repo_prepare_ubuntu
    fi
}

# ===========================================================================
# RHEL family
# ===========================================================================

_repo_prepare_rhel() {
    log "Configuring repositories (rhel${PLATFORM_MAJOR})..."

    # A previous offline install leaves repo files pointing at paths that no
    # longer exist. dnf then fails with a curl error on every command, which
    # looks like a network problem and is not.
    local stale
    for stale in offline-bundle offline-iso offline-baseos \
                 mellanox_mlnx_ofed_bundle doca-host-ofed offline-mlnx-ofed; do
        if [ -f "/etc/yum.repos.d/${stale}.repo" ]; then
            log "  removing stale repo config: ${stale}.repo"
            rm -f "/etc/yum.repos.d/${stale}.repo"
        fi
    done

    _repo_require_base_rhel

    dnf -y install dnf-plugins-core createrepo_c curl wget >>"$BUILD_LOG" 2>&1 || true

    dnf config-manager --add-repo \
        "$(platform_nvidia_repo_url)/cuda-rhel${PLATFORM_MAJOR}.repo" \
        >>"$BUILD_LOG" 2>&1 || true

    # dkms lives in EPEL. Without it the build falls back to a prebuilt kmod,
    # which is fine, but say so rather than failing later for an unclear reason.
    if ! dnf repolist enabled 2>/dev/null | grep -q '^epel'; then
        log "  adding EPEL (provides dkms)..."
        dnf -y install \
            "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${PLATFORM_MAJOR}.noarch.rpm" \
            >>"$BUILD_LOG" 2>&1 \
        || dnf -y install epel-release >>"$BUILD_LOG" 2>&1 \
        || warn "  EPEL unavailable; dkms may be missing from the bundle."
    fi

    # NVIDIA ships modular content. Without module_hotfixes dnf hides packages
    # that do not belong to an enabled stream.
    local rf
    for rf in /etc/yum.repos.d/*.repo; do
        [ -f "$rf" ] || continue
        if grep -qiE 'nvidia\.com|nvidia\.github\.io' "$rf" 2>/dev/null; then
            sed -i '/^module_hotfixes/d' "$rf" 2>/dev/null || true
            printf 'module_hotfixes=1\n' >>"$rf"
        fi
    done

    dnf clean all >>"$BUILD_LOG" 2>&1 || true
    _repo_health_rhel
}

# The NVIDIA repo carries only NVIDIA packages. gcc, make, systemd, /bin/sh and
# everything dkms needs come from the distribution's own BaseOS and AppStream.
# On an unregistered RHEL host those are disabled, every build dependency fails
# to resolve with "nothing provides /bin/sh", and the build looks like it
# simply stopped. Detect it here, where the remedy can be stated.
_repo_require_base_rhel() {
    local by_list=0 by_probe=0
    dnf repolist enabled 2>/dev/null | grep -qiE 'baseos|appstream' && by_list=1

    # Probe functionally with repoquery, not `dnf list --available`: glibc is
    # already installed, so --available reports nothing even on a healthy host.
    repo_rpm_query -q glibc 2>/dev/null | grep -q . && by_probe=1

    [ "$by_list" -eq 1 ] || [ "$by_probe" -eq 1 ] && { log "  base repos available."; return 0; }

    if grep -qiE 'Red Hat Enterprise' /etc/os-release 2>/dev/null; then
        die "BaseOS and AppStream are not available on this host.

   This RHEL system does not appear to be registered. Without registration
   those repositories are disabled, so gcc, make, systemd and dkms's
   dependencies cannot be resolved and the bundle would be unusable.

   Fix one of these, then re-run:
     sudo subscription-manager register --auto-attach
     sudo subscription-manager repos \\
       --enable rhel-${PLATFORM_MAJOR}-for-${PLATFORM_ARCH}-baseos-rpms \\
       --enable rhel-${PLATFORM_MAJOR}-for-${PLATFORM_ARCH}-appstream-rpms

   Or, with no subscription, mount the install ISO and add its BaseOS and
   AppStream directories as local repositories."
    fi

    die "BaseOS and AppStream are not available on this host.

   On Rocky and AlmaLinux these are enabled by default. Check that
   /etc/yum.repos.d/*.repo exist and are enabled, or mount the install ISO and
   add its BaseOS and AppStream directories as local repositories."
}

_repo_health_rhel() {
    log "  refreshing repository metadata..."
    local out
    out=$(dnf ${PLATFORM_RELEASEVER_OPT} makecache --refresh 2>&1 || true)
    printf '%s\n' "$out" >>"$BUILD_LOG"

    local failed
    failed=$(printf '%s\n' "$out" \
        | grep -oE "Failed to download metadata for repo '[^']+'" \
        | sed "s/.*repo '//; s/'//" | sort -u | tr '\n' ' ' || true)

    printf '%s\n' "$out" \
        | grep -qiE 'GPG signature verification error|Bad GPG signature|repomd\.xml signature' \
        && REPO_GPG_FAILURE=1

    if [ -z "$failed" ]; then
        log "  all enabled repositories readable."
        return 0
    fi

    REPO_DEGRADED="$failed"
    warn "  metadata refresh FAILED for: ${failed}"

    if printf '%s' "$failed" | grep -qiE 'cuda|nvidia'; then
        die "The NVIDIA repository itself could not be refreshed: ${failed}

   No NVIDIA package can be resolved in this state, so the bundle would be
   empty. Check network, proxy and DNS to developer.download.nvidia.com, then
   re-run. Raw dnf output is in ${BUILD_LOG}."
    fi
}

# ===========================================================================
# Ubuntu
# ===========================================================================

# Wait out unattended-upgrades and the apt-daily timers. On a freshly booted
# host these hold the dpkg lock for several minutes, and apt fails instantly
# rather than waiting.
_apt_wait_lock() {
    local max="${1:-300}" waited=0 announced=0
    command -v fuser >/dev/null 2>&1 || return 0
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
                 /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    while :; do
        local busy=0 lf
        for lf in "${locks[@]}"; do
            [ -e "$lf" ] || continue
            fuser "$lf" >/dev/null 2>&1 && { busy=1; break; }
        done
        if [ "$busy" -eq 0 ]; then
            local svc
            for svc in apt-daily apt-daily-upgrade unattended-upgrades; do
                systemctl is-active --quiet "${svc}.service" 2>/dev/null && { busy=1; break; }
            done
        fi
        [ "$busy" -eq 0 ] && break
        if [ "$announced" -eq 0 ]; then
            warn "  apt/dpkg is locked; waiting up to ${max}s..."
            announced=1
        fi
        [ "$waited" -ge "$max" ] && { warn "  still locked after ${max}s; proceeding."; break; }
        sleep 5; waited=$((waited + 5))
    done
    [ "$announced" -eq 1 ] && [ "$waited" -lt "$max" ] && log "  lock released after ${waited}s."
    return 0
}

# Test each glob independently.
#
# `ls a*.list a*.sources` returns non-zero when EITHER pattern misses, even
# though the other matched. cuda-keyring only ever writes a .list, so the
# combined form always reports "not found" on a perfectly healthy install —
# which then triggers a needless purge-and-reinstall that falls through to the
# legacy key path and aborts a working build.
_cuda_repo_registered() {
    compgen -G '/etc/apt/sources.list.d/cuda*.list'    >/dev/null 2>&1 || \
    compgen -G '/etc/apt/sources.list.d/cuda*.sources' >/dev/null 2>&1
}

_repo_prepare_ubuntu() {
    log "Configuring repositories (ubuntu${PLATFORM_UBUNTU_REPO})..."
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTS=(-o DPkg::Lock::Timeout=300)

    _apt_wait_lock 300

    # Purge rather than remove.
    #
    # On a re-run cuda-keyring is usually already installed at the same
    # version. dpkg -i of an identical version will NOT recreate a deleted
    # conffile, so deleting the .list and reinstalling leaves the repo
    # unregistered while apt-get update reports zero errors. The failure then
    # appears much later as "Unable to locate package cuda-libraries-X-Y" with
    # nothing pointing back here.
    dpkg --purge cuda-keyring >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/cuda*.list \
          /etc/apt/sources.list.d/nvidia*.list
    install -m 0755 -d /etc/apt/keyrings

    _repo_install_prereqs_ubuntu
    _repo_install_nvidia_key_ubuntu

    _apt_wait_lock 300
    if ! apt-get "${APT_OPTS[@]}" update -y >>"$BUILD_LOG" 2>&1; then
        warn "  apt-get update reported errors; see ${BUILD_LOG}."
        REPO_DEGRADED="apt"
    fi
    log "  repository configuration complete."
}

_repo_install_prereqs_ubuntu() {
    log "  installing prerequisites..."
    # Not fatal individually: a transient failure on one package must not abort
    # the builder. The hard check is on the binaries that actually get used.
    set +e
    apt-get "${APT_OPTS[@]}" update -y >>"$BUILD_LOG" 2>&1
    apt-get "${APT_OPTS[@]}" install -y \
        curl wget dpkg-dev ca-certificates gnupg software-properties-common \
        >>"$BUILD_LOG" 2>&1
    set -e

    local missing="" t
    for t in curl gpg dpkg-scanpackages; do
        command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
    done
    [ -z "$missing" ] || die "Required tools are missing after prerequisite install:${missing}

   Try manually:
     sudo apt-get update && sudo apt-get install -y curl gnupg dpkg-dev
   See ${BUILD_LOG} for the apt errors."
}

# Guard the key install.
#
# Under `set -euo pipefail` an unguarded `curl … | gpg` pipe is fatal: a
# transient failure fetching the key aborts the whole builder silently,
# immediately after the last log line, with no error anywhere.
_repo_install_nvidia_key_ubuntu() {
    local ok=0 deb=/tmp/cuda-keyring_1.1-1_all.deb
    log "  installing the NVIDIA repository signing key..."
    set +e

    curl -fsSL -o "$deb" \
        "$(platform_nvidia_repo_url)/cuda-keyring_1.1-1_all.deb" 2>>"$BUILD_LOG"

    if [ -s "$deb" ] && dpkg -i "$deb" >>"$BUILD_LOG" 2>&1; then
        if _cuda_repo_registered; then
            ok=1
        else
            # Reported success but wrote nothing: the same-version conffile
            # case. Force a clean install.
            dpkg --purge cuda-keyring >/dev/null 2>&1
            dpkg -i "$deb" >>"$BUILD_LOG" 2>&1 && _cuda_repo_registered && ok=1
        fi
    fi

    if [ "$ok" -eq 0 ]; then
        warn "  cuda-keyring unavailable; falling back to the .pub key."
        if curl -fsSL "$(platform_nvidia_repo_url)/3bf863cc.pub" 2>>"$BUILD_LOG" \
           | gpg --yes --dearmor -o /etc/apt/keyrings/nvidia-cuda.gpg 2>>"$BUILD_LOG" \
           && [ -s /etc/apt/keyrings/nvidia-cuda.gpg ]; then
            printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/nvidia-cuda.gpg] %s/ /\n' \
                "$(platform_nvidia_repo_url)" \
                > /etc/apt/sources.list.d/nvidia-cuda.list
            ok=1
        fi
    fi

    set -e
    [ "$ok" -eq 1 ] || die "Could not install the NVIDIA repository signing key for
   ubuntu${PLATFORM_UBUNTU_REPO}. Both cuda-keyring_1.1-1_all.deb and the .pub
   key failed.

   Confirm the repository path exists and is reachable:
     $(platform_nvidia_repo_url)/
   See ${BUILD_LOG} for the curl, dpkg and gpg errors."
    log "  signing key installed."
}

# ===========================================================================
# Gate
# ===========================================================================

repo_require_healthy() {
    [ -z "$REPO_DEGRADED" ] && return 0

    blank
    say "  Repositories that failed to refresh: ${REPO_DEGRADED}"
    if [ "$REPO_GPG_FAILURE" -eq 1 ]; then
        say "  The failure is a GPG signature error, not a network error."
        say "  Usually a cached repomd.xml signed with a rotated key:"
        say "      sudo rpm --import <that repo's gpgkey URL>"
        say "      sudo rm -rf /var/cache/dnf/<repo>* && sudo dnf clean all"
    fi
    blank

    die "Refusing to build against unreadable repositories.

   Package queries skip a repo that cannot be refreshed, so this build would
   complete and produce a bundle that is missing packages or pinned to an
   older version than the repository actually publishes. On the air-gapped
   target there is no network to discover or fix that.

   Fix the repositories above and re-run.
   To build anyway, which is not recommended: SKIP_REPO_HEALTH=1"
}
