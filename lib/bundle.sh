#!/usr/bin/env bash
# lib/bundle.sh — download, index, installer generation, packing

# ===========================================================================
# Generic package matchers
#
# Collection plumbing shared by every component module. The version is
# anchored on both sides: an unanchored match on "9.18.1" also accepts
# "9.18.19", which is how a bundle ends up carrying a version nobody chose.
# ===========================================================================

# pkg_rhel_match <name> <version>  -> NEVRA, or nothing
pkg_rhel_match() {
    repo_rpm_query --showduplicates "$1" \
        | grep -E "(:|-)${2}(-|\.|\.el|\.x86_64|\.noarch|$)" \
        | grep -E '\.(x86_64|noarch)$' \
        | sort -V | tail -n1 || true
}

# pkg_rhel_latest <name>  -> NEVRA of the newest build, or nothing
pkg_rhel_latest() {
    repo_rpm_query --showduplicates "$1" \
        | grep -E '\.(x86_64|noarch)$' \
        | sort -V | tail -n1 || true
}

# ---------------------------------------------------------------------------
# Transitional-stub filter
#
# Canonical retires an end-of-life driver branch by republishing every package
# of that branch as a transitional stub. The stub keeps the OLD branch number
# in its name and version, but its Depends point at the NEXT branch:
#
#     nvidia-driver-570-server-open 570.211.01-0ubuntu1.24.04.1
#       Depends: nvidia-driver-580-server-open
#
# The stub's version sorts ABOVE NVIDIA's real build of the same release
# (...-0ubuntu1.24.04.1 > ...-0ubuntu1), so "first madison row matching the
# requested version" picks the stub. It then gets pinned, branch isolation
# blocks the branch it forwards to, and apt aborts with held broken packages.
# An exact-version pin does not help: the stub's version string matches.
#
# A package version is treated as a stub when at least one Depends clause can
# be satisfied ONLY by an NVIDIA package of a different driver major. A clause
# that lists the package's own branch, or any branch-neutral alternative, is
# an ordinary OR-chain and is left alone.
# ---------------------------------------------------------------------------
_DEB_STUB_DIR="$(mktemp -d /tmp/airgap-gpu-stub.XXXXXX 2>/dev/null || printf '/tmp/airgap-gpu-stub.%s' "$$")"
mkdir -p "$_DEB_STUB_DIR" 2>/dev/null || true
trap 'rm -rf "$_DEB_STUB_DIR" 2>/dev/null || true' EXIT

# Print "<package> <version>" for every stub version of the named packages.
deb_stub_scan() {
    [ "$#" -gt 0 ] || return 0
    apt-cache show "$@" 2>/dev/null | awk '
        function branch_of(name,   padded) {
            if (name !~ /nvidia/ && name !~ /^cuda-drivers-/) return ""
            padded = name "-"
            if (match(padded, /-[0-9][0-9][0-9]-/)) return substr(padded, RSTART + 1, 3)
            return ""
        }
        function emit() {
            if (pkg != "" && ver != "" && own_branch != "" && is_stub) print pkg " " ver
            ver = ""; is_stub = 0
        }
        /^Package:/ { emit(); pkg = $2; own_branch = branch_of(pkg); next }
        /^Version:/ { ver = $2; next }
        /^(Pre-)?Depends:/ {
            if (own_branch == "") next
            deps = $0
            sub(/^[^:]*:[ \t]*/, "", deps)
            gsub(/\([^)]*\)/, "", deps)
            n_clause = split(deps, clause, ",")
            for (i = 1; i <= n_clause; i++) {
                n_alt = split(clause[i], alt, "|")
                same = 0; other = 0; neutral = 0
                for (j = 1; j <= n_alt; j++) {
                    dep = alt[j]
                    gsub(/[ \t]/, "", dep); sub(/:.*/, "", dep)
                    if (dep == "") continue
                    b = branch_of(dep)
                    if (b == "")              neutral = 1
                    else if (b == own_branch) same = 1
                    else                      other = 1
                }
                if (other && !same && !neutral) is_stub = 1
            }
            next
        }
        END { emit() }' | sort -u || true
}

# Stub versions of one package, cached on disk so the answer survives the
# command substitutions every caller runs in.
_deb_stub_versions() {
    local pkg="$1" cache
    case "$pkg" in
        nvidia-*|libnvidia-*|xserver-xorg-video-nvidia-*|cuda-drivers-*) ;;
        *) return 0 ;;
    esac
    cache="${_DEB_STUB_DIR}/${pkg}"
    if [ ! -f "$cache" ]; then
        deb_stub_scan "$pkg" | awk -v p="$pkg" '$1 == p {print $2}' >"${cache}.tmp" 2>/dev/null || true
        mv -f "${cache}.tmp" "$cache" 2>/dev/null || true
    fi
    cat "$cache" 2>/dev/null || true
}

# Drop-in for `apt-cache madison` that hides stub rows. Output is identical to
# madison when no stub exists.
deb_madison() {
    local rows pkg ver drop=""
    rows=$(apt-cache madison "$@" 2>/dev/null || true)
    [ -n "$rows" ] || return 0
    for pkg in $(printf '%s\n' "$rows" | awk -F'|' '{gsub(/[ \t]/,"",$1); print $1}' | sort -u); do
        for ver in $(_deb_stub_versions "$pkg"); do
            drop+="${pkg}|${ver} "
        done
    done
    if [ -z "$drop" ]; then
        printf '%s\n' "$rows"
        return 0
    fi
    printf '%s\n' "$rows" | awk -F'|' -v drop="$drop" '
        BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) if (d[i] != "") hide[d[i]] = 1 }
        { p = $1; v = $2; gsub(/[ \t]/, "", p); gsub(/[ \t]/, "", v)
          if (!((p "|" v) in hide)) print }'
}

# One visible summary of every stub hidden during this build.
deb_stub_report() {
    local cache pkg ver shown=0
    for cache in "$_DEB_STUB_DIR"/*; do
        [ -s "$cache" ] || continue
        case "$cache" in *.tmp) continue ;; esac
        pkg="$(basename "$cache")"
        while read -r ver; do
            [ "$shown" -eq 0 ] && warn "  Ubuntu archive transitional stubs found (an end-of-life branch forwarded to another branch); ignored:"
            shown=1
            warn "    ${pkg}=${ver}"
        done <"$cache"
    done
    return 0
}

# pkg_deb_match <name> <version>  -> apt version string, or nothing
pkg_deb_match() {
    deb_madison "$1" \
        | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
        | grep -F "$2" | head -n1 || true
}

pkg_deb_latest() {
    deb_madison "$1" \
        | awk -F'|' '{gsub(/ /,"",$2); print $2}' | head -n1 || true
}

pkg_deb_exists() { apt-cache show "$1" >/dev/null 2>&1; }

# Add to the collection lists. Both are idempotent on name.
pkg_add_rhel() {
    local nevra="$1" component="$2" role="$3" t
    [ -n "$nevra" ] || return 1
    for t in "${RPM_TARGETS[@]:-}"; do [ "$t" = "$nevra" ] && return 0; done
    RPM_TARGETS+=("$nevra")
    manifest_record "$component" "$role" "$nevra"
    log "  ${role}: ${nevra}"
}

pkg_add_deb() {
    local name="$1" version="$2" component="$3" role="$4" t
    [ -n "$version" ] || return 1
    for t in "${DEB_TARGETS[@]:-}"; do [ "$t" = "${name}=${version}" ] && return 0; done
    DEB_TARGETS+=("${name}=${version}")
    DEB_PIN_ENTRIES+=("Package: ${name}"$'\n'"Pin: version ${version}"$'\n'"Pin-Priority: 1001")
    manifest_record "$component" "$role" "${name}=${version}"
    log "  ${role}: ${name}=${version}"
}

# ===========================================================================
# Download
# ===========================================================================

bundle_download() {
    if [ "$PLATFORM_FAMILY" = "rhel" ]; then
        _bundle_download_rhel
    else
        _bundle_download_ubuntu
    fi
    _bundle_purge_kernel_bodies
    _bundle_purge_precompiled_kmods
}

# The bundle installs a driver against the target's running kernel and must
# never change it. kernel-devel-matched is the usual vector: it is a meta that
# always tracks the repository's newest kernel, so it pulls kernel-core, the
# target boots a different kernel, and modules built for the old one stop
# loading.
#
# kernel-headers is deliberately NOT excluded. It sits on a hard dependency
# chain — kmod-nvidia-open-dkms -> dkms -> gcc -> glibc-devel -> kernel-headers
# — and excluding it fails the entire resolve. It ships compile-time headers
# only and cannot change the booted kernel.
_rhel_kernel_excludes() {
    printf '%s\n' \
        --exclude=kernel \
        --exclude=kernel-core \
        --exclude=kernel-modules \
        --exclude=kernel-modules-core \
        --exclude=kernel-modules-extra \
        --exclude=kernel-devel-matched \
        --exclude=kernel-uki-virt
}

_bundle_download_rhel() {
    [ "${#RPM_TARGETS[@]}" -gt 0 ] || die "Nothing was resolved to download."

    local -a kexcl=()
    mapfile -t kexcl < <(_rhel_kernel_excludes)

    log "Downloading NVIDIA packages (${#RPM_TARGETS[@]} targets + dependencies)..."
    # strict=0 so one unavailable transitive dependency is skipped instead of
    # aborting the whole transaction; skip_if_unavailable so an unrelated
    # broken repo cannot zero out the NVIDIA payload.
    dnf -y ${PLATFORM_RELEASEVER_OPT} download --resolve --alldeps \
        --setopt=strict=0 \
        --setopt='*.skip_if_unavailable=1' \
        --arch "$PLATFORM_ARCH" --arch noarch \
        --downloaddir="$PKG_DIR" \
        "${kexcl[@]}" ${RPM_EXCLUDES[0]+"${RPM_EXCLUDES[@]}"} "${RPM_TARGETS[@]}" \
        >>"$BUILD_LOG" 2>&1 || warn "  some dependencies were skipped; see ${BUILD_LOG}"

    log "Downloading build toolchain (best effort)..."
    local -a extras=(gcc make binutils perl elfutils-libelf-devel)
    local pkg
    for pkg in "kernel-headers-${PLATFORM_KERNEL}" "kernel-devel-${PLATFORM_KERNEL}" dkms; do
        if repo_rpm_query "$pkg" 2>/dev/null | grep -q .; then
            extras+=("$pkg")
        else
            warn "  ${pkg} is not in any repository; skipping."
        fi
    done
    dnf -y ${PLATFORM_RELEASEVER_OPT} download --resolve --alldeps \
        --setopt=strict=0 \
        --setopt='*.skip_if_unavailable=1' \
        --arch "$PLATFORM_ARCH" --arch noarch \
        --downloaddir="$PKG_DIR" \
        "${kexcl[@]}" "${extras[@]}" \
        >>"$BUILD_LOG" 2>&1 || warn "  some build extras were unavailable (non-fatal)"

    find "$PKG_DIR" -type f -name '*.i686.rpm' -delete 2>/dev/null || true

    local count
    count=$(find "$PKG_DIR" -maxdepth 1 -name '*.rpm' | wc -l)
    if [ "$count" -eq 0 ]; then
        blank
        say "  Diagnostic lines from the build log:"
        grep -iE 'error|no match|nothing provides|cannot|unable|conflict|excluded|filtered' \
            "$BUILD_LOG" 2>/dev/null | tail -20 | sed 's/^/    /' || true
        blank
        die "No packages were downloaded. See the lines above and ${BUILD_LOG}.
   If the resolution step succeeded, this is not a network problem."
    fi
    log "  ${count} RPMs collected."
}

_bundle_download_ubuntu() {
    [ "${#DEB_TARGETS[@]}" -gt 0 ] || [ "${#DRIVER_ALT_SETS[@]}" -gt 0 ] \
        || die "Nothing was resolved to download."

    local pref=/etc/apt/preferences.d/airgap-gpu-pin
    _bundle_write_pin "$pref"

    # Clear the archive cache so a stale .deb from an earlier run cannot be
    # mistaken for this build's output.
    find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -delete 2>/dev/null || true

    local -a names=()
    local t
    for t in "${DEB_TARGETS[@]}"; do names+=("${t%%=*}"); done
    names+=(dkms build-essential "linux-headers-${PLATFORM_KERNEL}")

    log "Downloading packages and dependencies..."
    _apt_wait_lock 300
    local rc=0
    if [ "${#DRIVER_ALT_SETS[@]}" -eq 0 ]; then
        _bundle_apt_fetch "${names[@]}" || rc=$?
    else
        _bundle_pick_driver_set "${names[@]}" || rc=$?
        if [ "$rc" -eq 0 ]; then
            local chosen
            for chosen in $DRIVER_SET_CHOSEN; do
                names+=("${chosen%%=*}")
                DEB_TARGETS+=("$chosen")
            done
            manifest_record driver "set" "$DRIVER_SET_CHOSEN"
            log "  driver: ${DRIVER_SET_CHOSEN}"
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        _bundle_apt_diagnostics "${names[@]}"
        rm -f "$pref"
        die "Package download failed on unresolved dependencies.
   See the diagnostics above and ${BUILD_LOG}."
    fi

    find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -exec mv -f {} "$PKG_DIR/" \; 2>/dev/null || true

    _bundle_force_download_deps
    _bundle_decode_filenames

    # Copy the pin file into the bundle before removing it from the host. The
    # target needs the same constraints, or apt there is free to "helpfully"
    # resolve a newer driver branch out of the local repo.
    cp "$pref" "${BUNDLE_DIR}/airgap-gpu-pin"
    rm -f "$pref"

    local count
    count=$(find "$PKG_DIR" -maxdepth 1 -name '*.deb' | wc -l)
    [ "$count" -eq 0 ] && die "No .deb files were collected. See ${BUILD_LOG}."
    log "  ${count} .deb files collected."
}

_bundle_apt_fetch() {
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        --download-only --no-install-recommends \
        -o APT::Get::Assume-Yes=true \
        install "$@" >>"$BUILD_LOG" 2>&1
}

# True when the apt archive cache holds nvidia-smi and a kernel-module source
# (DKMS or a prebuilt linux-modules-nvidia). A set that resolves and downloads
# but lacks either one installs "successfully" and leaves a host with no
# working driver.
_bundle_driver_payload_ok() {
    local deb base has_smi=0 has_kmod=0
    for deb in /var/cache/apt/archives/*.deb; do
        [ -f "$deb" ] || continue
        base="$(basename "$deb")"
        case "$base" in nvidia-dkms-*|linux-modules-nvidia-*) has_kmod=1 ;; esac
        case "$base" in
            *nvidia*)
                if [ "$has_smi" -eq 0 ] && dpkg-deb -c "$deb" 2>/dev/null \
                     | grep -E '\./usr/bin/nvidia-smi( |$)' >/dev/null; then
                    has_smi=1
                fi ;;
        esac
    done
    [ "$has_smi" -eq 1 ] && [ "$has_kmod" -eq 1 ]
}

# Choose the driver package set by evidence rather than by a fixed list.
#
# NVIDIA has changed its own package split between releases (at 570.211.01,
# libnvidia-compute-570 began to conflict with older nvidia-utils-570), so any
# hard-coded child list eventually breaks. Each candidate set is tried in
# order against the final pin file:
#   1) simulate   -> must resolve
#   2) download   -> must succeed
#   3) payload    -> must ship nvidia-smi and a kernel-module package
# The first set passing all three wins. If none ships both, the first set that
# downloaded cleanly is used and the operator is told to verify on the target.
DRIVER_SET_CHOSEN=""
_bundle_pick_driver_set() {
    local set fallback="" index=0 sim rc
    local -a parts
    DRIVER_SET_CHOSEN=""

    for set in "${DRIVER_ALT_SETS[@]}"; do
        index=$((index + 1))
        # shellcheck disable=SC2206
        parts=( $set )
        rc=0
        sim=$(DEBIAN_FRONTEND=noninteractive apt-get install -s --no-install-recommends \
                  "$@" "${parts[@]}" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            log "    driver set [${index}] does not resolve; skipped: ${set}"
            printf '%s\n' "$sim" | grep -E '^ [a-z0-9]|^E:' | head -n 8 \
                | sed 's/^/        /' | tee -a "$BUILD_LOG" || true
            continue
        fi
        find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -delete 2>/dev/null || true
        if ! _bundle_apt_fetch "$@" "${parts[@]}"; then
            log "    driver set [${index}] resolved but the download failed; skipped."
            continue
        fi
        [ -z "$fallback" ] && fallback="$set"
        if _bundle_driver_payload_ok; then
            DRIVER_SET_CHOSEN="$set"
            log "    driver set [${index}] resolves, downloads, and ships nvidia-smi + a kernel module."
            return 0
        fi
        log "    driver set [${index}] downloads but lacks nvidia-smi or a kernel-module package; trying next."
    done

    if [ -n "$fallback" ]; then
        warn "  No candidate driver set ships BOTH nvidia-smi and a kernel module. Using: ${fallback}"
        warn "  Verify on the target after install: nvidia-smi and 'dkms status'."
        DRIVER_SET_CHOSEN="$fallback"
        find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -delete 2>/dev/null || true
        # shellcheck disable=SC2206
        parts=( $fallback )
        _bundle_apt_fetch "$@" "${parts[@]}"
        return $?
    fi

    warn "  None of the ${#DRIVER_ALT_SETS[@]} candidate R${DRIVER_MAJOR} driver sets resolved (details above)."
    {
        printf 'Package metadata of the driver candidates:\n'
        local pv
        for set in "${DRIVER_ALT_SETS[@]}"; do
            for pv in $set; do
                apt-cache show "$pv" 2>/dev/null \
                    | grep -E '^(Package|Version|Depends|Pre-Depends|Conflicts|Breaks|Provides):' || true
                printf '\n'
            done
        done
    } >>"$BUILD_LOG" 2>&1 || true
    return 100
}

_bundle_write_pin() {
    local path="$1"
    {
        printf '# Generated by airgap-gpu %s\n\n' "$AIRGAP_GPU_VERSION"
        local entry
        for entry in "${DEB_PIN_ENTRIES[@]:-}"; do
            printf '%s\n\n' "$entry"
        done
        # Branch isolation entries, when the Pro module supplied them.
        local block
        for block in "${DEB_BLOCK_ENTRIES[@]:-}"; do
            printf '%s\n\n' "$block"
        done
    } > "$path"
    log "  pin file written ($(grep -c '^Package:' "$path") entries)"
}

# apt-get --download-only skips anything already installed on the build host.
# Those same packages are usually absent on the air-gapped target, so the
# bundle would be missing exactly the dependencies that make the install work.
# apt-get download fetches regardless of install state.
_bundle_force_download_deps() {
    log "  force-downloading build dependencies..."

    # Component modules add packages here whose dependency trees would
    # otherwise be skipped because the build host already has them installed.
    local -a roots=(dkms build-essential "linux-headers-${PLATFORM_KERNEL}")
    [ "${#DEB_FORCE_DOWNLOAD[@]}" -gt 0 ] && roots+=("${DEB_FORCE_DOWNLOAD[@]}")

    local recurse
    recurse=$(apt-cache depends --recurse --no-recommends --no-suggests \
                --no-conflicts --no-breaks --no-replaces --no-enhances \
                "${roots[@]}" 2>/dev/null \
              | grep '^\w' | grep -v '^<' | sort -u || true)

    local count=0 pkg
    ( cd "$PKG_DIR" || exit 0
      while IFS= read -r pkg; do
          [ -z "$pkg" ] && continue
          # NVIDIA-family packages are already here at the pinned version via
          # the pin-controlled pass. apt-get download ignores preferences, so
          # fetching them again would put a second, unpinned version in the
          # bundle and the offline install could pick the wrong one.
          case "$pkg" in
              cuda|cuda-*|libcudnn*|cudnn*|libcuda*|libnvidia-*|nvidia-*| \
              xserver-xorg-video-nvidia-*|libnccl*|nccl-*) continue ;;
          esac
          apt-get download "$pkg" >/dev/null 2>&1 || true
      done <<<"$recurse"
    )
    count=$(find "$PKG_DIR" -maxdepth 1 -name '*.deb' | wc -l)
    log "  ${count} .deb files after dependency sweep."
}

# apt preserves URL-encoded names from its cache. dpkg-scanpackages then writes
# encoded Filename: fields, and apt on the target cannot match them.
_bundle_decode_filenames() {
    shopt -s nullglob
    local f base decoded
    for f in "$PKG_DIR"/*%*.deb; do
        base=$(basename "$f")
        decoded="${base//%3a/:}"; decoded="${decoded//%3A/:}"
        decoded="${decoded//%2b/+}"; decoded="${decoded//%2B/+}"
        decoded="${decoded//%7e/\~}"; decoded="${decoded//%7E/\~}"
        [ "$base" != "$decoded" ] && mv -f "$f" "${PKG_DIR}/${decoded}" 2>/dev/null || true
    done
    shopt -u nullglob
}

_bundle_apt_diagnostics() {
    blank
    say "  Dependency diagnostics"
    say "  ----------------------"
    tail -n 40 "$BUILD_LOG" 2>/dev/null | grep -E '^(E:|N:|W:|The following|  )' | tail -20 | sed 's/^/    /' || true
    blank
    DEBIAN_FRONTEND=noninteractive apt-get install -s --no-install-recommends "$@" 2>&1 \
        | grep -E '^(E:|N:|The following|  [a-zA-Z])' | head -30 | sed 's/^/    /' || true
    blank
}

# ===========================================================================
# Post-download sweeps (correctness, not licensed)
# ===========================================================================

_bundle_purge_kernel_bodies() {
    [ "$PLATFORM_FAMILY" = "rhel" ] || return 0
    local purged=0 f name
    for f in "$PKG_DIR"/kernel-*.rpm; do
        [ -f "$f" ] || continue
        name=$(rpm -qp --queryformat '%{NAME}' "$f" 2>/dev/null || true)
        case "$name" in
            kernel|kernel-core|kernel-modules|kernel-modules-core| \
            kernel-modules-extra|kernel-devel-matched|kernel-uki-virt)
                rm -f "$f"; purged=$((purged + 1)) ;;
        esac
    done
    [ "$purged" -gt 0 ] && \
        warn "  removed ${purged} kernel package(s); the target keeps its own kernel."
    return 0
}

# NVIDIA also publishes precompiled kmods whose names embed one exact kernel
# version. They hard-require that kernel, so on a target running anything else
# the transaction fails outright. The DKMS-source kmods build against whatever
# the target is running and are kept.
_bundle_purge_precompiled_kmods() {
    [ "$PLATFORM_FAMILY" = "rhel" ] || return 0
    local purged=0 f name
    for f in "$PKG_DIR"/kmod-nvidia-*.rpm; do
        [ -f "$f" ] || continue
        name=$(rpm -qp --queryformat '%{NAME}' "$f" 2>/dev/null || true)
        case "$name" in
            kmod-nvidia-open-dkms|kmod-nvidia-latest-dkms|kmod-nvidia-dkms) ;;
            kmod-nvidia-*) rm -f "$f"; purged=$((purged + 1)) ;;
        esac
    done
    [ "$purged" -gt 0 ] && \
        warn "  removed ${purged} precompiled kmod(s); DKMS builds against the target's kernel."
    return 0
}

# ===========================================================================
# Index
# ===========================================================================

bundle_index() {
    if [ "$PLATFORM_FAMILY" = "rhel" ]; then
        createrepo_c "$PKG_DIR" >>"$BUILD_LOG" 2>&1 \
            || die "createrepo_c failed; the offline repo would be unusable. See ${BUILD_LOG}."
        log "Local repository index created."
    else
        ( cd "$PKG_DIR" || exit 1
          dpkg-scanpackages . /dev/null 2>/dev/null >Packages || true
          gzip -9c Packages >Packages.gz || true )
        log "APT index generated."
    fi
}

# ===========================================================================
# Offline installer
# ===========================================================================

bundle_write_installer() {
    local out="${BUNDLE_DIR}/install_offline.sh"
    local install_list=""
    if [ "$PLATFORM_FAMILY" = "rhel" ]; then
        install_list="${RPM_TARGETS[*]}"
    else
        install_list="${DEB_TARGETS[*]}"
    fi

    cat >"$out" <<INSTALLER
#!/usr/bin/env bash
# airgap-gpu offline installer
# Built for : ${PLATFORM_PRETTY}
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
set -euo pipefail

DIR="\$(cd "\$(dirname "\$0")" && pwd)"
LOG="\$DIR/install.log"
: >"\$LOG"
exec > >(tee -a "\$LOG") 2>&1

say() { printf '%s %s\n' "\$(date '+%H:%M:%S')" "\$1"; }
die() { printf '%s ERROR: %s\n' "\$(date '+%H:%M:%S')" "\$1"; exit 1; }

[ "\${EUID:-\$(id -u)}" -eq 0 ] || die "Root required. Re-run with sudo."
[ -d "\$DIR/packages" ] || die "packages/ not found. Run this from inside the extracted bundle."

. /etc/os-release
RUNNING_KERNEL="\$(uname -r)"
say "Target: \$PRETTY_NAME, kernel \$RUNNING_KERNEL"

say "Blacklisting nouveau..."
cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
command -v dracut >/dev/null 2>&1 && dracut --force >/dev/null 2>&1 || true
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u >/dev/null 2>&1 || true

INSTALLER

    if [ "$PLATFORM_FAMILY" = "rhel" ]; then
        cat >>"$out" <<'INSTALLER_RHEL'
cat >/etc/yum.repos.d/airgap-gpu.repo <<EOF
[airgap-gpu]
name=airgap-gpu offline bundle
baseurl=file://$DIR/packages
enabled=1
gpgcheck=0
module_hotfixes=1
EOF

REPO_OPTS="--disablerepo=* --enablerepo=airgap-gpu"
BASE=$(dnf repolist enabled 2>/dev/null | awk 'NR>1 {print $1}' \
       | grep -iE 'baseos|appstream' | paste -sd, - || true)
[ -n "$BASE" ] && REPO_OPTS="--disablerepo=* --enablerepo=airgap-gpu,${BASE}"

# Lock the running kernel. The bundle ships no kernel, but the ISO or a base
# repo may carry a newer one; booting it would strand every module built here.
KERNEL_LOCK="--setopt=exclude=kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra,kernel-uki-virt"
KERNEL_BEFORE="$(uname -r)"

dnf clean all >/dev/null 2>&1 || true

# The CUDA repo ships nvidia-driver as a DNF module; an enabled default stream
# makes dnf filter out the DKMS kmods with no useful diagnostic.
dnf -y $REPO_OPTS module reset nvidia-driver >/dev/null 2>&1 || true

say "Installing build dependencies..."
dnf -y $REPO_OPTS $KERNEL_LOCK install \
    gcc make perl binutils elfutils-libelf-devel \
    "kernel-devel-${RUNNING_KERNEL}" "kernel-headers-${RUNNING_KERNEL}" \
    >/dev/null 2>&1 || true

rpm -q "kernel-devel-${RUNNING_KERNEL}" >/dev/null 2>&1 \
  || say "WARNING: kernel-devel-${RUNNING_KERNEL} is absent; the DKMS build may fail."

say "Installing the NVIDIA stack..."
# shellcheck disable=SC2086
dnf -y $REPO_OPTS $KERNEL_LOCK install --allowerasing $INSTALL_LIST

KERNEL_AFTER="$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-core-//')"
if [ -n "$KERNEL_AFTER" ] && [ "$KERNEL_AFTER" != "$KERNEL_BEFORE" ]; then
    say "WARNING: a different kernel is present: $KERNEL_AFTER"
    say "  Booting it will strand the modules built for $KERNEL_BEFORE."
    say "  To stay put: sudo grubby --set-default /boot/vmlinuz-$KERNEL_BEFORE"
else
    say "Kernel unchanged. Safe to reboot."
fi
INSTALLER_RHEL
    else
        cat >>"$out" <<'INSTALLER_DEB'
export DEBIAN_FRONTEND=noninteractive

# Disable the internet sources for the duration of the install.
#
# A fresh Ubuntu install carries archive.ubuntu.com entries. On an air-gapped
# host apt waits on DNS for each, and if any dependency is missing locally it
# falls through to those sources and the install aborts on "Failed to fetch".
BACKUP="/var/tmp/airgap-gpu-sources.$$"
mkdir -p "$BACKUP"
if [ -f /etc/apt/sources.list ]; then
    cp /etc/apt/sources.list "$BACKUP/sources.list"
    sed -i 's|^\(deb\|deb-src\)[[:space:]]|# AIRGAP-DISABLED &|' /etc/apt/sources.list
fi
shopt -s nullglob
for lst in /etc/apt/sources.list.d/*.list; do
    [ "$(basename "$lst")" = "airgap-gpu.list" ] && continue
    if grep -qE '(archive|security|ports|cdn)\.ubuntu\.com|debian\.org' "$lst" 2>/dev/null; then
        cp "$lst" "$BACKUP/"
        sed -i 's|^\(deb\|deb-src\)[[:space:]]|# AIRGAP-DISABLED &|' "$lst"
    fi
done

restore_sources() {
    [ -f "$BACKUP/sources.list" ] && cp -f "$BACKUP/sources.list" /etc/apt/sources.list
    for f in "$BACKUP"/*.list; do
        [ -f "$f" ] && [ "$(basename "$f")" != "sources.list" ] \
            && cp -f "$f" "/etc/apt/sources.list.d/$(basename "$f")"
    done
    rm -rf "$BACKUP"
    rm -f /etc/apt/preferences.d/airgap-gpu-pin
    say "Restored the original apt sources."
}
trap restore_sources EXIT

printf 'deb [trusted=yes] file://%s/packages ./\n' "$DIR" \
    >/etc/apt/sources.list.d/airgap-gpu.list

# The same version constraints the bundle was built under. Without them apt
# here is free to resolve a newer driver branch out of the local repo.
if [ -f "$DIR/airgap-gpu-pin" ]; then
    cp "$DIR/airgap-gpu-pin" /etc/apt/preferences.d/airgap-gpu-pin
    say "Applied $(grep -c '^Package:' /etc/apt/preferences.d/airgap-gpu-pin) version pins."
else
    say "WARNING: no pin file in the bundle; apt may select a different driver branch."
fi

APT_OPTS=(
    -o APT::Sandbox::User=root
    -o APT::Get::AllowUnauthenticated=true
    -o APT::Get::Assume-Yes=true
    -o Acquire::AllowInsecureRepositories=true
    -o Acquire::Languages=none
    -o Acquire::http::Timeout=3
)

apt-get update -y "${APT_OPTS[@]}" >/dev/null 2>&1 || true

say "Installing build dependencies..."
apt-get install -y --no-install-recommends --allow-unauthenticated --fix-broken \
    "${APT_OPTS[@]}" build-essential dkms "linux-headers-${RUNNING_KERNEL}" \
    2>&1 | grep -v '^Ign:' || true

say "Installing the NVIDIA stack..."
# shellcheck disable=SC2086
apt-get install -y --reinstall --allow-downgrades --no-install-recommends \
    --allow-unauthenticated "${APT_OPTS[@]}" $INSTALL_LIST
INSTALLER_DEB
    fi

    cat >>"$out" <<'INSTALLER_TAIL'

say "Done. Reboot, then run: sudo bash all_check.sh"
INSTALLER_TAIL

    # Substitute the install list into the generated script. Done by
    # replacement rather than expansion so the heredocs above stay quoted and
    # nothing in them is evaluated at build time.
    sed -i "s|\$INSTALL_LIST|${install_list}|g" "$out"
    chmod +x "$out"
    log "install_offline.sh generated."
}

# ===========================================================================
# Post-install checker
# ===========================================================================

bundle_write_checker() {
    local out="${BUNDLE_DIR}/all_check.sh"
    cat >"$out" <<'CHECKER'
#!/usr/bin/env bash
# airgap-gpu post-install check
[ -f /etc/profile.d/cuda.sh ] && . /etc/profile.d/cuda.sh 2>/dev/null || true
ok()   { printf '  [ok]   %s\n' "$1"; }
bad()  { printf '  [warn] %s\n' "$1"; }
head_() { printf '\n== %s ==\n' "$1"; }

head_ "Driver"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
else
    bad "nvidia-smi not found. Reboot first; if it persists, check: dmesg | grep -i NVRM"
fi
CHECKER

    if [ "${ENABLE[cuda]:-0}" -eq 1 ]; then
        cat >>"$out" <<'CHECKER'

head_ "CUDA"
if command -v nvcc >/dev/null 2>&1; then nvcc --version; else
    bad "nvcc not found. Try: source /etc/profile.d/cuda.sh"
fi
CHECKER
    fi

    if [ "${ENABLE[fabricmanager]:-0}" -eq 1 ]; then
        cat >>"$out" <<'CHECKER'

head_ "Fabric Manager"
if systemctl list-unit-files 2>/dev/null | grep -q nvidia-fabricmanager; then
    state=$(systemctl is-active nvidia-fabricmanager 2>/dev/null || echo inactive)
    [ "$state" = active ] && ok "nvidia-fabricmanager running" || {
        bad "nvidia-fabricmanager is $state"
        printf '         Fabric Manager is only required on NVSwitch systems\n'
        printf '         (HGX, DGX). On other GPUs this is expected.\n'
        printf '         Diagnose: journalctl -u nvidia-fabricmanager -n 30 --no-pager\n'
    }
else
    bad "nvidia-fabricmanager unit not found; a reboot may be needed."
fi
CHECKER
    fi

    if [ "${ENABLE[dcgm]:-0}" -eq 1 ]; then
        cat >>"$out" <<'CHECKER'

head_ "DCGM"
if command -v dcgmi >/dev/null 2>&1; then
    dcgmi --version 2>/dev/null | head -3
    dcgmi discovery -l 2>/dev/null | head -5 || true
else
    bad "dcgmi not found."
fi
CHECKER
    fi

    printf '\nprintf "\\n== check complete ==\\n"\n' >>"$out"
    chmod +x "$out"
    log "all_check.sh generated."
}

# ===========================================================================
# Summary and packing
# ===========================================================================

bundle_summary() {
    local ext total_bytes=0 total_count=0 f sz
    [ "$PLATFORM_FAMILY" = "rhel" ] && ext="rpm" || ext="deb"

    blank
    say "  Bundle contents"
    while IFS= read -r f; do
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total_bytes=$((total_bytes + sz))
        total_count=$((total_count + 1))
    done < <(find "$BUNDLE_DIR" -type f -name "*.${ext}" 2>/dev/null)

    printf '    %-20s %4d packages  %8.1f MB\n' \
        "total" "$total_count" "$(awk "BEGIN{print ${total_bytes}/1048576}")" \
        | tee -a "$BUILD_LOG"
    blank
}

bundle_pack() {
    log "Writing ${OUT_TAR}..."
    tar -czf "$OUT_TAR" -C "$WORKDIR" "$BUNDLE_NAME"
}
