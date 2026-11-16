#!/usr/bin/env bash
# airgap-gpu — offline bundle builder for the NVIDIA data-center GPU stack
#
# Builds a self-contained package bundle on an online host that matches the
# air-gapped target's OS, then installs it on a machine with no network.
#
# Usage:
#   sudo ./airgap-gpu.sh                      interactive
#   sudo AIRGAP_GPU_NONINTERACTIVE=1 ./airgap-gpu.sh
#   sudo ./airgap-gpu.sh --activate <key>     register this build machine
#   sudo ./airgap-gpu.sh --deactivate         release this machine's seat
#
# No vendor binaries are redistributed. Packages are fetched from NVIDIA's own
# repositories under the operator's entitlement.

set -euo pipefail

readonly AIRGAP_GPU_VERSION="0.1.0"
readonly SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SELF_DIR}/lib"
readonly PRO_DIR="${SELF_DIR}/pro"

# ---------------------------------------------------------------------------
# Module loading
#
# Logging is loaded first and unconditionally: every other module reports
# through it, and a failure before it is in place would be silent.
# ---------------------------------------------------------------------------
# shellcheck source=lib/log.sh
. "${LIB_DIR}/log.sh"
# shellcheck source=lib/platform.sh
. "${LIB_DIR}/platform.sh"
# shellcheck source=lib/license.sh
. "${LIB_DIR}/license.sh"

# ---------------------------------------------------------------------------
# Subcommands that run before anything else is set up
# ---------------------------------------------------------------------------
case "${1:-}" in
    --activate)
        [ -n "${2:-}" ] || die "Usage: $0 --activate <license-key>"
        platform_require_root
        license_activate "$2"
        exit 0
        ;;
    --deactivate)
        platform_require_root
        license_deactivate
        exit 0
        ;;
    --version)
        printf 'airgap-gpu %s\n' "$AIRGAP_GPU_VERSION"
        exit 0
        ;;
    --help|-h)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Preflight
#
# Everything that can refuse the run happens before the operator is asked to
# make a single selection. Discovering mid-TUI that the host is unsuitable
# wastes their time and, worse, trains them to click through warnings.
# ---------------------------------------------------------------------------
platform_require_root
platform_detect

WORKDIR="${PWD}"
BUNDLE_NAME="${PLATFORM_PREFIX}_bundle"
BUNDLE_DIR="${WORKDIR}/${BUNDLE_NAME}"
OUT_TAR="${WORKDIR}/${BUNDLE_NAME}.tar.gz"

# Refuse to overwrite. A half-overwritten bundle is indistinguishable from a
# complete one until it fails on the target, where nothing can be checked.
if [ -d "$BUNDLE_DIR" ] || [ -f "$OUT_TAR" ]; then
    printf '\n'
    printf 'Existing bundle artifacts found:\n'
    [ -d "$BUNDLE_DIR" ] && printf '  directory : %s\n' "$BUNDLE_DIR"
    [ -f "$OUT_TAR" ]    && printf '  tarball   : %s\n' "$OUT_TAR"
    printf '\nRemove them and re-run:\n\n'
    printf '    rm -rf %s %s\n\n' "$BUNDLE_DIR" "$OUT_TAR"
    exit 1
fi

PKG_DIR="${BUNDLE_DIR}/packages"
mkdir -p "$PKG_DIR" "${BUNDLE_DIR}/keys"

BUILD_LOG="${BUNDLE_DIR}/build.log"
TRACE_LOG="${BUNDLE_DIR}/trace.log"
MANIFEST="${BUNDLE_DIR}/manifest.tsv"
: >"$BUILD_LOG"; : >"$TRACE_LOG"; : >"$MANIFEST"

log_start_trace

log "airgap-gpu ${AIRGAP_GPU_VERSION}"

# ---------------------------------------------------------------------------
# Licensing and Pro module loading
# ---------------------------------------------------------------------------
license_check || true
license_report

PRO_LOADED=0
if license_pro_enabled && [ -d "$PRO_DIR" ]; then
    for _mod in isolation minorguard kernel cuda ctk cudnn nccl dcgm \
                fabricmanager doca verify; do
        if [ -r "${PRO_DIR}/${_mod}.sh" ]; then
            # shellcheck disable=SC1090
            . "${PRO_DIR}/${_mod}.sh"
        fi
    done
    PRO_LOADED=1
    log "Pro modules loaded."
elif license_pro_enabled; then
    warn "A license is registered but the pro/ directory is missing."
    warn "  Re-download the Pro modules from the Polar customer portal."
fi

# ---------------------------------------------------------------------------
# Free modules
# ---------------------------------------------------------------------------
# shellcheck source=lib/repo.sh
. "${LIB_DIR}/repo.sh"
# shellcheck source=lib/driver.sh
. "${LIB_DIR}/driver.sh"
# shellcheck source=lib/bundle.sh
. "${LIB_DIR}/bundle.sh"
# shellcheck source=lib/select.sh
. "${LIB_DIR}/select.sh"

# ---------------------------------------------------------------------------
# Collection state
#
# Declared here so the free modules can populate them and the Pro modules can
# extend them, without either having to know whether the other is loaded.
# ---------------------------------------------------------------------------
declare -a RPM_EXCLUDES=()        # --exclude=NEVRA, from branch isolation
declare -a DEB_BLOCK_ENTRIES=()   # Pin-Priority -1 stanzas, from branch isolation
declare -a DEB_FORCE_DOWNLOAD=()  # fetched regardless of build-host install state
declare -a DRIVER_ALT_SETS=()     # Ubuntu: candidate driver install sets, chosen at download

# ---------------------------------------------------------------------------
# Selection
#
# REQ records what the operator asked for, captured before any repository is
# queried. Collection may later find a component unresolvable and disable it;
# comparing the two at the end is what stops a bundle shipping without a
# component the operator believes is in it.
# ---------------------------------------------------------------------------
select_components

declare -A REQ=()
for _c in "${!ENABLE[@]}"; do REQ[$_c]="${ENABLE[$_c]}"; done

# ---------------------------------------------------------------------------
# Repository setup
# ---------------------------------------------------------------------------
repo_prepare

# A repository that failed to refresh is not a warning. Queries silently skip
# it, so the build can look successful while the bundle is missing packages or
# pinned to an older version than the repo actually publishes — and that only
# surfaces on the target, where there is no network.
[ "${SKIP_REPO_HEALTH:-0}" -eq 1 ] || repo_require_healthy

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------
driver_collect

if [ "$PRO_LOADED" -eq 1 ]; then
    [ "${ENABLE[cuda]:-0}"          -eq 1 ] && cuda_collect
    [ "${ENABLE[ctk]:-0}"           -eq 1 ] && ctk_collect
    [ "${ENABLE[cudnn]:-0}"         -eq 1 ] && cudnn_collect
    [ "${ENABLE[nccl]:-0}"          -eq 1 ] && nccl_collect
    [ "${ENABLE[dcgm]:-0}"          -eq 1 ] && dcgm_collect
    [ "${ENABLE[fabricmanager]:-0}" -eq 1 ] && fabricmanager_collect

    # Branch isolation runs after every collector, so it can see the full set
    # of names that need protecting from cross-branch resolution.
    isolation_apply
fi

bundle_download

# DOCA collects into its own directory with its own repository, so it runs
# after the main download rather than contributing to it.
[ "$PRO_LOADED" -eq 1 ] && [ "${ENABLE[doca]:-0}" -eq 1 ] && doca_collect

if [ "$PRO_LOADED" -eq 1 ]; then
    # Order matters. Branch and version sweeps first, so the minor sweep and
    # the index see the final package set.
    isolation_sweep
    cudnn_sweep
    nccl_sweep
    minorguard_sweep      # drop packages tagged a newer OS minor than this host
    kernel_bundle_target  # bundle kernel-devel for KERNEL=, when given
fi

bundle_index

# ---------------------------------------------------------------------------
# Verification
#
# The target has no second chance, so the bundle does not leave this host
# unverified. Both gates can be bypassed, deliberately awkwardly.
# ---------------------------------------------------------------------------
if [ "$PRO_LOADED" -eq 1 ]; then
    [ "${SKIP_OFFLINE_DRYRUN:-0}" -eq 1 ] || verify_offline_closure
    [ "${SKIP_BUNDLE_CHECK:-0}"   -eq 1 ] || verify_bundle REQ
fi

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
bundle_write_installer
bundle_write_checker
bundle_summary
bundle_pack

log_stop_trace

blank
say "Bundle: ${OUT_TAR}"
say "Log:    ${BUILD_LOG}"
blank
say "On the air-gapped target:"
say "  tar -xzf ${BUNDLE_NAME}.tar.gz"
say "  cd ${BUNDLE_NAME} && sudo bash install_offline.sh"
say "  sudo reboot && sudo bash all_check.sh"
