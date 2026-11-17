#!/usr/bin/env bash
# lib/driver.sh — GPU driver resolution
#
# This module is free, and it is complete. A driver bundle it produces is a
# working driver bundle. The variant rules below are where most hand-rolled
# scripts go wrong, and shipping a free tool that fails on them would be worse
# than shipping nothing.

# Populated by the collectors and consumed by bundle_download.
declare -a RPM_TARGETS=()     # NEVRAs for dnf
declare -a DEB_TARGETS=()     # name=version for apt
declare -a DEB_PIN_ENTRIES=() # apt preferences stanzas

DRIVER_VERSION=""
DRIVER_MAJOR=""
DRIVER_VARIANT=""             # ubuntu only: "" | -open | -server | -server-open
DRIVER_OPEN_KMOD=0

manifest_record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$MANIFEST"
}

driver_collect() {
    DRIVER_VERSION="${VERSIONS[driver]}"
    DRIVER_MAJOR="${DRIVER_VERSION%%.*}"
    log "Driver ${DRIVER_VERSION} (R${DRIVER_MAJOR})"

    if [ "$PLATFORM_FAMILY" = "rhel" ]; then
        _driver_collect_rhel
    else
        _driver_collect_ubuntu
    fi
}

# ===========================================================================
# RHEL / Rocky / Alma / CentOS
# ===========================================================================

# Match one package name at exactly DRIVER_VERSION. The version is anchored on
# both sides: an unanchored match on "580.167.08" also accepts "580.167.081".
_rhel_match_version() {
    local name="$1"
    repo_rpm_query --showduplicates "$name" \
        | grep -E "(:|-)${DRIVER_VERSION}(-|\.el|\.x86_64|\.noarch|$)" \
        | grep -E '\.(x86_64|noarch)$' \
        | sort -V | tail -n1 || true
}

_rhel_add() {
    # $1 = NEVRA, $2 = manifest role
    local nevra="$1" role="$2"
    local name="${nevra%%-[0-9]*}"
    local t
    for t in "${RPM_TARGETS[@]:-}"; do
        [ "$t" = "$nevra" ] && return 0
    done
    RPM_TARGETS+=("$nevra")
    manifest_record driver "$role" "$nevra"
    log "  ${role}: ${nevra}"
}

_driver_collect_rhel() {
    # The CUDA repo ships nvidia-driver as a DNF module. With a default stream
    # enabled, dnf reports both DKMS kmods as "filtered out by modular
    # filtering" and the driver install fails with no useful diagnostic.
    # Reset before querying, and again on the target before installing.
    dnf -y module reset nvidia-driver >>"$BUILD_LOG" 2>&1 || true

    # Package naming on current branches:
    #   nvidia-open              open driver meta, noarch, version-locked
    #   kmod-nvidia-open-dkms    open kernel module
    #   kmod-nvidia-latest-dkms  closed kernel module
    #   cuda-drivers / nvidia-driver   proprietary entry points
    #
    # There is no package called nvidia-open-dkms. nvidia-open-<major> are
    # legacy per-branch metas from the R560/R565 era; on current branches the
    # bare nvidia-open carries the version.
    local meta="" meta_name=""
    local cand
    for cand in nvidia-open "nvidia-open-${DRIVER_MAJOR}" cuda-drivers nvidia-driver; do
        meta=$(_rhel_match_version "$cand")
        if [ -n "$meta" ]; then meta_name="$cand"; break; fi
    done

    if [ -z "$meta" ]; then
        local avail
        avail=$(repo_rpm_query --showduplicates nvidia-open nvidia-driver cuda-drivers \
                | grep -oE '[0-9]{3}\.[0-9]+\.[0-9]+' | sort -V -u | tail -n5 || true)
        if [ -z "$avail" ]; then
            die "The NVIDIA repository returned no driver packages at all.

   This is a repository problem, not a wrong version: nvidia-open,
   nvidia-driver and cuda-drivers all came back empty, so nothing could be
   listed. Check that the repo is reachable and its metadata is readable:

     curl -I $(platform_nvidia_repo_url)/
     sudo dnf clean all && sudo dnf makecache"
        fi
        die "Driver ${DRIVER_VERSION} is not published in the NVIDIA repository.

   Recent versions available for this platform:
${avail}"
    fi

    _rhel_add "$meta" "meta(${meta_name})"

    case "$meta_name" in
        nvidia-open*) DRIVER_OPEN_KMOD=1 ;;
    esac

    # Blackwell B200/B300 require the open kernel module. Collect it whenever
    # it exists at this version, even alongside a proprietary meta — the
    # operator may be targeting Blackwell with a closed-meta selection.
    local kmod
    kmod=$(_rhel_match_version kmod-nvidia-open-dkms)
    if [ -n "$kmod" ]; then
        _rhel_add "$kmod" "kmod(open)"
        DRIVER_OPEN_KMOD=1
    elif [ "$DRIVER_OPEN_KMOD" -eq 1 ]; then
        warn "  kmod-nvidia-open-dkms is absent at ${DRIVER_VERSION}; the open"
        warn "  driver will have no kernel module to build."
    fi

    # The open and closed kmods conflict. Only collect the closed one when the
    # open one is genuinely unavailable.
    if [ "$DRIVER_OPEN_KMOD" -eq 0 ]; then
        kmod=$(_rhel_match_version kmod-nvidia-latest-dkms)
        [ -n "$kmod" ] && _rhel_add "$kmod" "kmod(closed)"
    else
        log "  open kernel module selected; skipping the closed DKMS kmod"
    fi

    # nvidia-kmod-common is required by both DKMS kmods. Offline resolution
    # cannot pull it implicitly, so it has to be named.
    local sub
    for sub in nvidia-kmod-common \
               nvidia-driver-cuda \
               nvidia-driver-cuda-libs \
               nvidia-driver-libs \
               nvidia-driver-NVML; do
        local m
        m=$(_rhel_match_version "$sub")
        [ -n "$m" ] && _rhel_add "$m" "sub(${sub})"
    done
}

# ===========================================================================
# Ubuntu
# ===========================================================================

# Resolve a version from the NVIDIA CUDA repo only.
#
# The Ubuntu archive publishes older-branch metapackages as transitional stubs
# that forward-upgrade to the current LTSB: installing R550 from
# archive.ubuntu.com yields R580 binaries despite the package name. The stub
# declares a hard dependency rather than an alternative, so branch pins cannot
# save you. The origin column of apt-cache madison is what separates them,
# and deb_madison additionally hides stub rows whose version string still
# matches the requested release.
_ubuntu_version_from_nvidia_repo() {
    deb_madison "$1" \
        | grep -F 'developer.download.nvidia.com' \
        | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
        | grep -F "$DRIVER_VERSION" | head -n1 || true
}

_ubuntu_version_any_origin() {
    deb_madison "$1" \
        | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
        | grep -F "$DRIVER_VERSION" | head -n1 || true
}

_deb_add() {
    # $1 = name, $2 = version, $3 = manifest role
    DEB_TARGETS+=("${1}=${2}")
    DEB_PIN_ENTRIES+=("Package: ${1}"$'\n'"Pin: version ${2}"$'\n'"Pin-Priority: 1001")
    manifest_record driver "$3" "${1}=${2}"
    log "  ${3}: ${1}=${2}"
}

_driver_collect_ubuntu() {
    # Fabric Manager and libnvidia-nscq hard-depend on
    # nvidia-kernel-common-<major>-server-<version>: NVSwitch and NVLink fabric
    # need symbols present only in the server kernel module build. When Fabric
    # Manager is selected the candidate list must not fall back to a
    # non-server variant, or that dependency becomes unsatisfiable on the
    # target with an opaque "held broken packages".
    local -a candidates
    if [ "${ENABLE[fabricmanager]:-0}" -eq 1 ]; then
        candidates=(
            "nvidia-driver-${DRIVER_MAJOR}-server-open"
            "nvidia-driver-${DRIVER_MAJOR}-server"
        )
    else
        candidates=(
            "nvidia-driver-${DRIVER_MAJOR}-server-open"
            "nvidia-driver-${DRIVER_MAJOR}-server"
            "nvidia-driver-${DRIVER_MAJOR}-open"
            "nvidia-driver-${DRIVER_MAJOR}"
        )
    fi

    local base="" version=""
    local cand
    for cand in "${candidates[@]}"; do
        version=$(_ubuntu_version_from_nvidia_repo "$cand")
        if [ -n "$version" ]; then base="$cand"; break; fi
    done

    # The concrete variant meta often lives in the Ubuntu archive while the
    # NVIDIA repo carries only cuda-drivers and the concrete children. Accept
    # the archive's copy when it exists at our exact version, pinned to that
    # version so the stub's forward-upgrade cannot trigger.
    if [ -z "$version" ]; then
        for cand in "${candidates[@]}"; do
            version=$(_ubuntu_version_any_origin "$cand")
            if [ -n "$version" ]; then
                base="$cand"
                log "  variant meta from the Ubuntu archive, pinned to ${DRIVER_VERSION}"
                break
            fi
        done
    fi

    if [ -z "$version" ]; then
        # No variant meta carries a real build at this version. Say so when the
        # raw index still lists one: that row is a transitional stub, and the
        # operator would otherwise wonder why a visible package was ignored.
        local raw
        for cand in "${candidates[@]}"; do
            raw=$(apt-cache madison "$cand" 2>/dev/null \
                  | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
                  | grep -F "$DRIVER_VERSION" | head -n1 || true)
            [ -n "$raw" ] && warn "  ${cand}=${raw} is a transitional stub in the Ubuntu archive (it forwards to another driver branch); ignored."
        done

        # Fabric Manager needs the server kernel-module build, which only the
        # server variant metas provide. There is nothing to fall back to.
        if [ "${ENABLE[fabricmanager]:-0}" -eq 1 ]; then
            deb_stub_report
            _ubuntu_driver_unavailable "${candidates[@]}"
        fi

        _ubuntu_build_alt_sets
        if [ "${#DRIVER_ALT_SETS[@]}" -eq 0 ]; then
            deb_stub_report
            _ubuntu_driver_unavailable "${candidates[@]}"
        fi
        log "  no variant meta at ${DRIVER_VERSION}; ${#DRIVER_ALT_SETS[@]} candidate install set(s), chosen by simulation at download:"
        local n=0 set
        for set in "${DRIVER_ALT_SETS[@]}"; do
            n=$((n + 1)); log "    [${n}] ${set}"
        done
        _ubuntu_collect_children pin-only
        _ubuntu_block_stubs
        deb_stub_report
        return 0
    fi

    case "$base" in
        *-server-open) DRIVER_VARIANT="-server-open" ;;
        *-server)      DRIVER_VARIANT="-server"      ;;
        *-open)        DRIVER_VARIANT="-open"        ;;
        *)             DRIVER_VARIANT=""             ;;
    esac

    _deb_add "$base" "$version" "meta"
    _ubuntu_collect_children
    _ubuntu_block_stubs
    deb_stub_report
}

# Build the ordered list of candidate driver install sets for the case where
# no variant meta exists at the requested version. A set is kept only when
# every package in it has a real, non-stub build at that version. The download
# step simulates each against the final pin file and keeps the first that
# resolves, downloads, and actually ships nvidia-smi plus a kernel module.
_ubuntu_build_alt_sets() {
    DRIVER_ALT_SETS=()

    local dkms="" cand
    for cand in "nvidia-dkms-${DRIVER_MAJOR}-open" "nvidia-dkms-${DRIVER_MAJOR}"; do
        if [ -n "$(_ubuntu_version_any_origin "$cand")" ]; then dkms="$cand"; break; fi
    done
    local flavor=""
    case "$dkms" in *-open) flavor="-open" ;; esac
    DRIVER_VARIANT="$flavor"
    [ -n "$dkms" ] || warn "  no nvidia-dkms-${DRIVER_MAJOR}[-open] at ${DRIVER_VERSION}; the kernel module may be missing."

    # 1) headless meta + utils: the data-center standard, no X stack
    _ubuntu_alt_add "nvidia-headless-${DRIVER_MAJOR}${flavor}" "nvidia-utils-${DRIVER_MAJOR}"
    # 2) headless meta alone, for packagings where nvidia-smi left nvidia-utils
    _ubuntu_alt_add "nvidia-headless-${DRIVER_MAJOR}${flavor}"
    # 3) the full driver meta of the same flavor
    _ubuntu_alt_add "nvidia-driver-${DRIVER_MAJOR}${flavor}"
    # 4) NVIDIA's own top meta
    _ubuntu_alt_add "cuda-drivers-${DRIVER_MAJOR}"

    # 5) concrete children, then the same without nvidia-utils
    local -a core=() core_no_utils=()
    for cand in "$dkms" \
                "nvidia-driver-cuda-${DRIVER_MAJOR}" \
                "nvidia-kernel-common-${DRIVER_MAJOR}" \
                "libnvidia-compute-${DRIVER_MAJOR}" \
                "libnvidia-cfg1-${DRIVER_MAJOR}" \
                "nvidia-utils-${DRIVER_MAJOR}" \
                "libnvidia-gl-${DRIVER_MAJOR}"; do
        [ -n "$cand" ] || continue
        [ -n "$(_ubuntu_version_any_origin "$cand")" ] && core+=("$cand")
    done
    [ "${#core[@]}" -gt 0 ] && _ubuntu_alt_add "${core[@]}"

    for cand in ${core[0]+"${core[@]}"}; do
        [ "$cand" = "nvidia-utils-${DRIVER_MAJOR}" ] && continue
        core_no_utils+=("$cand")
    done
    [ -n "$(_ubuntu_version_any_origin "nvidia-compute-utils-${DRIVER_MAJOR}")" ] \
        && core_no_utils+=("nvidia-compute-utils-${DRIVER_MAJOR}")
    [ "${#core_no_utils[@]}" -gt 0 ] && _ubuntu_alt_add "${core_no_utils[@]}"
    return 0
}

# Append one candidate set, as "name=version name=version", unless any member
# lacks a real build at the requested version or the set is already listed.
_ubuntu_alt_add() {
    local set="" name version existing
    for name in "$@"; do
        [ -n "$name" ] || continue
        version=$(_ubuntu_version_any_origin "$name")
        [ -n "$version" ] || return 0
        set+=" ${name}=${version}"
    done
    set="${set# }"
    [ -n "$set" ] || return 0
    for existing in ${DRIVER_ALT_SETS[0]+"${DRIVER_ALT_SETS[@]}"}; do
        [ "$existing" = "$set" ] && return 0
    done
    DRIVER_ALT_SETS+=("$set")
}

# Hard-block the stub versions of every package of this branch: priority -1 on
# that exact version only, so real builds of the same name stay selectable.
# This covers names that are not pinned explicitly but that apt may still pull
# as an unversioned dependency, where the stub would otherwise win as the
# candidate because it sorts above the real build.
_ubuntu_block_stubs() {
    local names blocked=0 pkg ver
    names=$(apt-cache pkgnames 2>/dev/null \
            | grep -E "^((lib)?nvidia-.*-${DRIVER_MAJOR}(-server)?(-open)?|xserver-xorg-video-nvidia-${DRIVER_MAJOR}(-server)?|cuda-drivers(-fabricmanager)?-${DRIVER_MAJOR})$" \
            | sort -u || true)
    [ -n "$names" ] || return 0
    while read -r pkg ver; do
        [ -n "${pkg:-}" ] && [ -n "${ver:-}" ] || continue
        DEB_BLOCK_ENTRIES+=("Package: ${pkg}"$'\n'"Pin: version ${ver}"$'\n'"Pin-Priority: -1")
        blocked=$((blocked + 1))
    done < <(deb_stub_scan $names)
    [ "$blocked" -gt 0 ] && log "  transitional stubs hard-blocked: ${blocked} version(s)"
    return 0
}

# The variant suffix rule.
#
# The "-open" part of a variant name applies ONLY to kernel module packages.
# Userspace children are shared across the family and carry just "-server".
#
#   nvidia-driver-580-server-open depends on
#     nvidia-dkms-580-server-open           kernel module  -server-open
#     nvidia-kernel-source-580-server-open  kernel module  -server-open
#     libnvidia-gl-580-server               userspace      -server
#     libnvidia-compute-580-server          userspace      -server
#     nvidia-kernel-common-580-server       userspace      -server
#     nvidia-utils-580-server               userspace      -server
#
# Filtering children by exact suffix match drops every userspace package. The
# bundle then builds cleanly online and fails on the target with
# "Depends: libnvidia-gl-580-server but it is not going to be installed".
_ubuntu_child_matches_variant() {
    local child="$1"

    # Kernel module packages must match the selected variant EXACTLY. Every
    # flavour of nvidia-dkms-<major>* provides the same virtual package and
    # they conflict with one another, so putting two in the pin file produces
    # the held-broken-packages failure this whole module exists to avoid.
    case "$child" in
        "nvidia-dkms-${DRIVER_MAJOR}"*|"nvidia-kernel-source-${DRIVER_MAJOR}"*)
            local want="nvidia-dkms-${DRIVER_MAJOR}${DRIVER_VARIANT}"
            local want_src="nvidia-kernel-source-${DRIVER_MAJOR}${DRIVER_VARIANT}"
            [ "$child" = "$want" ] || [ "$child" = "$want_src" ]
            return $?
            ;;
    esac

    # Userspace children are shared across the family and carry only -server.
    # A -server-open driver depends on libnvidia-gl-<major>-server, not on a
    # -server-open build of it, so the family — not the exact suffix — is what
    # decides.
    case "$DRIVER_VARIANT" in
        -server-open|-server)
            case "$child" in
                *-server) return 0 ;;   # the shared server userspace
                *-open)   return 1 ;;   # a non-server open build
                *)        return 0 ;;   # variant-neutral
            esac
            ;;
        -open)
            case "$child" in
                *-server-open|*-server) return 1 ;;
                *)                      return 0 ;;
            esac
            ;;
        *)
            case "$child" in
                *-server-open|*-server|*-open) return 1 ;;
                *)                             return 0 ;;
            esac
            ;;
    esac
}

# With "pin-only", children are pinned but kept off the install list: the
# candidate-set path lets the chosen set pull them, and only needs every one
# of them held at the requested version.
_ubuntu_collect_children() {
    local mode="${1:-install}"
    local raw child version count=0
    raw=$(apt-cache pkgnames 2>/dev/null \
          | grep -E "^(lib)?nvidia-.*-${DRIVER_MAJOR}(-server)?(-open)?$" \
          | sort -u || true)

    while IFS= read -r child; do
        [ -z "$child" ] && continue
        # Skip the metas themselves; one is already the install target.
        case "$child" in
            "nvidia-driver-${DRIVER_MAJOR}"|"nvidia-driver-${DRIVER_MAJOR}-"*|\
            "nvidia-open-${DRIVER_MAJOR}"|"nvidia-fabricmanager-${DRIVER_MAJOR}"|\
            "libnvidia-nscq-${DRIVER_MAJOR}")
                continue ;;
        esac
        _ubuntu_child_matches_variant "$child" || continue
        version=$(_ubuntu_version_any_origin "$child")
        [ -z "$version" ] && continue
        if [ "$mode" = "pin-only" ]; then
            DEB_PIN_ENTRIES+=("Package: ${child}"$'\n'"Pin: version ${version}"$'\n'"Pin-Priority: 1001")
        else
            _deb_add "$child" "$version" "child"
        fi
        count=$((count + 1))
    done <<<"$raw"

    # nvidia-persistenced carries no major in its name and ships only from the
    # NVIDIA repo. Left unpinned, apt resolves it to the newest branch.
    local pv
    pv=$(_ubuntu_version_any_origin nvidia-persistenced)
    if [ -n "$pv" ]; then
        if [ "$mode" = "pin-only" ]; then
            DEB_PIN_ENTRIES+=("Package: nvidia-persistenced"$'\n'"Pin: version ${pv}"$'\n'"Pin-Priority: 1001")
        else
            _deb_add nvidia-persistenced "$pv" "child"
        fi
        count=$((count + 1))
    fi

    log "  ${count} driver child packages pinned (variant: ${DRIVER_VARIANT:-none})"
    [ "$count" -eq 0 ] && warn "  No child packages matched — the install will almost certainly fail."
}

_ubuntu_driver_unavailable() {
    local avail=""
    local cand versions
    for cand in "$@"; do
        versions=$(deb_madison "$cand" \
                   | grep -F 'developer.download.nvidia.com' \
                   | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
                   | sort -V -u | tail -n5 || true)
        [ -n "$versions" ] && avail+="  ${cand}:"$'\n'"$(printf '%s\n' "$versions" | sed 's/^/    /')"$'\n'
    done

    die "Driver ${DRIVER_VERSION} is not published in the NVIDIA repository for
   ${PLATFORM_PRETTY}.

   NVIDIA publishes only selected maintenance releases per branch.
${avail:-   No versions of this branch were found at all.}
   The Ubuntu archive is deliberately not used as a fallback: it publishes
   older-branch metapackages as transitional stubs that forward-upgrade to the
   current LTSB, so installing one gives you a different driver branch than the
   package name claims.

   Pick a version listed above and re-run."
}
