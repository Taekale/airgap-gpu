#!/usr/bin/env bash
# lib/platform.sh — OS detection, repo-path derivation, releasever policy
#
# Every rule here is a correctness fact about how these distributions publish
# packages, not a preference. Getting one wrong produces an empty bundle or a
# bundle that changes the target's OS minor version.

PLATFORM_ID=""          # rhel | rocky | almalinux | centos | ubuntu
PLATFORM_FAMILY=""      # rhel | debian
PLATFORM_VERSION=""     # 9.7 | 24.04
PLATFORM_MAJOR=""       # 9 | 24
PLATFORM_MINOR=""       # 7 | 04
PLATFORM_PRETTY=""
PLATFORM_ARCH=""
PLATFORM_KERNEL=""

# Bundle naming prefix, derived from the distribution.
PLATFORM_PREFIX=""

# RHEL-family: the value to pass as --releasever, and the assembled option.
PLATFORM_RELEASEVER=""
PLATFORM_RELEASEVER_OPT=""

# Ubuntu: the repo path component NVIDIA publishes under (2204 / 2404 / 2604).
PLATFORM_UBUNTU_REPO=""

# Platforms the builder accepts. The build host and the air-gapped target must
# match: downloaded .deb/.rpm are distribution-version specific, so a bundle
# built on a different release will not resolve on the target.
platform_supported() {
    case "${1}:${2}" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
        rhel:9.*|rocky:9.*|almalinux:9.*|centos:9.*) return 0 ;;
    esac
    return 1
}

platform_detect() {
    [ -r /etc/os-release ] || die "/etc/os-release is unreadable; cannot identify this host."

    # Read os-release in a subshell-free way but without leaking its many
    # variables into the caller's namespace beyond what we copy out.
    local _id _ver _pretty _idlike
    # shellcheck disable=SC1091
    _id=$(. /etc/os-release && printf '%s' "${ID:-}")
    _ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    _pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")
    _idlike=$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")

    if ! platform_supported "$_id" "$_ver"; then
        die "Unsupported platform: ${_id:-unknown} ${_ver:-unknown}

   Supported build hosts:
     Ubuntu 22.04 / 24.04 / 26.04
     RHEL 9.x / Rocky 9.x / AlmaLinux 9.x / CentOS Stream 9

   The build host must match the air-gapped target's OS and version. Packages
   downloaded here are distribution-version specific and will not resolve on a
   target running something else."
    fi

    PLATFORM_ID="$_id"
    PLATFORM_VERSION="$_ver"
    PLATFORM_PRETTY="$_pretty"
    PLATFORM_MAJOR="${_ver%%.*}"
    PLATFORM_MINOR="${_ver#*.}"
    [ "$PLATFORM_MINOR" = "$_ver" ] && PLATFORM_MINOR=""
    PLATFORM_ARCH="$(uname -m)"
    PLATFORM_KERNEL="$(uname -r)"

    case "$_id" in
        ubuntu) PLATFORM_FAMILY="debian" ;;
        rhel|rocky|almalinux|centos) PLATFORM_FAMILY="rhel" ;;
        *)
            case "$_idlike" in
                *debian*) PLATFORM_FAMILY="debian" ;;
                *)        PLATFORM_FAMILY="rhel"   ;;
            esac
            ;;
    esac

    case "$_id" in
        rocky)     PLATFORM_PREFIX="rocky" ;;
        rhel)      PLATFORM_PREFIX="rhel"  ;;
        almalinux) PLATFORM_PREFIX="alma"  ;;
        centos)    PLATFORM_PREFIX="centos";;
        ubuntu)    PLATFORM_PREFIX="ubuntu";;
        *)         PLATFORM_PREFIX="$_id"  ;;
    esac

    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        platform_init_ubuntu
    else
        platform_init_rhel
    fi

    log "Build host: ${PLATFORM_PRETTY} (${PLATFORM_FAMILY} family, ${PLATFORM_ARCH}, kernel ${PLATFORM_KERNEL})"
}

# --- Ubuntu ------------------------------------------------------------------

platform_init_ubuntu() {
    # NVIDIA publishes under a dotless version component: ubuntu2204, ubuntu2404.
    PLATFORM_UBUNTU_REPO="${PLATFORM_VERSION//./}"

    # 26.04 has a native repo carrying both driver and CUDA 13.x. Its package
    # names differ from 24.04, so the 24.04 repo is deliberately NOT registered
    # as a fallback: the two are flat repos sharing an origin, apt priorities
    # cannot cleanly separate them, and mixing the two name sets breaks
    # dependency resolution. Add 24.04 by hand for one missing component if it
    # ever comes to that.
    if [ "$PLATFORM_UBUNTU_REPO" = "2604" ]; then
        log "  Ubuntu 26.04: using the native ubuntu2604 repo for driver and CUDA."
        log "  (ubuntu2404 is not registered as a fallback — package names differ.)"
    fi
}

# --- RHEL family -------------------------------------------------------------

platform_init_rhel() {
    # releasever semantics differ between RHEL and the rebuilds, and getting it
    # wrong is silently catastrophic in opposite directions.
    #
    #   RHEL     the CDN exposes minor EUS paths (.../rhel9/9.7/...), so pinning
    #            the minor both works and blocks newer-minor errata.
    #
    #   Rocky /  mirrors set $releasever to the MAJOR only. There is no
    #   Alma     .../9.7/BaseOS/ path at all — only .../9/BaseOS/. Passing a
    #            minor 404s BaseOS, AppStream and Extras; dnf drops them, the
    #            gcc / make / glibc / dkms chain vanishes, and the build
    #            produces zero packages.
    #
    # On the rebuilds the newer-minor leak is instead blocked downstream, by the
    # post-download minor sweep and the kernel lock.
    case "$PLATFORM_ID" in
        rocky|almalinux)
            PLATFORM_RELEASEVER="$PLATFORM_MAJOR"
            ;;
        *)
            PLATFORM_RELEASEVER="$PLATFORM_VERSION"
            ;;
    esac
    PLATFORM_RELEASEVER_OPT="--releasever=${PLATFORM_RELEASEVER}"
    log "  dnf releasever pinned to ${PLATFORM_RELEASEVER}"
}

# Resolve the NVIDIA CUDA repository base URL for this host.
platform_nvidia_repo_url() {
    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        printf 'https://developer.download.nvidia.com/compute/cuda/repos/ubuntu%s/%s' \
            "$PLATFORM_UBUNTU_REPO" "$PLATFORM_ARCH"
    else
        printf 'https://developer.download.nvidia.com/compute/cuda/repos/rhel%s/%s' \
            "$PLATFORM_MAJOR" "$PLATFORM_ARCH"
    fi
}

# True when the host's package minor is newer than the build host's own.
# Used by the post-download sweep; see the OS minor leak rule.
platform_release_minor_of() {
    # $1 = an rpm RELEASE string, e.g. "1.el9_8"
    printf '%s' "$1" \
        | grep -oE "el${PLATFORM_MAJOR}_[0-9]+" \
        | head -1 \
        | sed -E "s/el${PLATFORM_MAJOR}_//"
}

platform_require_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "Root privileges are required. Re-run with sudo."
}
