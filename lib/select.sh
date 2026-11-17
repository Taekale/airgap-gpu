#!/usr/bin/env bash
# lib/select.sh — component and version selection
#
# Defaults track the NVIDIA AI Enterprise Infrastructure 4.10 LTSB matrix.
# Every default below has been built, installed and brought up on RHEL 9.x,
# Rocky 9.x, Ubuntu 24.04 and Ubuntu 22.04.

declare -A ENABLE=(
    [driver]=0 [cuda]=0 [ctk]=0 [cudnn]=0 [fabricmanager]=0
    [nccl]=0 [dcgm]=0 [doca]=0
)

declare -A VERSIONS=(
    [driver]="580.167.08"
    [cuda]="13-2"
    [ctk]="1.19.1"
    [cudnn]="9.18.1"
    [nccl]="2.29.2"
    [dcgm]="4.6.0"
    [doca]="3.3.0"
)

CUDA_SERIES=""      # 13-2
CUDA_MAJOR=""       # 13
CUDA_PATCH=""       # set only when the operator pinned a patch level

select_components() {
    if [ "${AIRGAP_GPU_NONINTERACTIVE:-0}" = "1" ]; then
        _select_defaults
    else
        command -v whiptail >/dev/null 2>&1 \
            || die "whiptail is required for the interactive selector.
   Install it, or re-run with AIRGAP_GPU_NONINTERACTIVE=1."
        _select_interactive
    fi
    _select_derive
    _select_validate
    _select_echo
}

_select_defaults() {
    ENABLE[driver]=1
    if [ "$PRO_LOADED" -eq 1 ]; then
        local c
        for c in cuda ctk cudnn fabricmanager nccl dcgm doca; do ENABLE[$c]=1; done
    fi
    log "Non-interactive: building the default stack."
}

_select_interactive() {
    local title="airgap-gpu ${AIRGAP_GPU_VERSION}"
    local -a items=(
        "DRIVER" "GPU driver (data-center, ${VERSIONS[driver]})" ON
    )

    if [ "$PRO_LOADED" -eq 1 ]; then
        items+=(
            "CUDA"          "CUDA Toolkit (${VERSIONS[cuda]} family)"            ON
            "CTK"           "Container Toolkit"                                  OFF
            "CUDNN"         "cuDNN (requires CUDA)"                              OFF
            "NCCL"          "NCCL (requires CUDA)"                               OFF
            "DCGM"          "Data Center GPU Manager"                            OFF
            "FABRICMANAGER" "Fabric Manager + NVLink stack (requires driver)"    OFF
            "DOCA"          "DOCA / OFED (NVIDIA networking)"                    OFF
        )
    fi

    local note=""
    [ "$PRO_LOADED" -eq 0 ] && note="

Only the driver is available in the free build. CUDA, cuDNN, NCCL,
DCGM, Fabric Manager and DOCA need a Pro license:
  sudo ./airgap-gpu.sh --activate <key>"

    local picked
    picked=$(whiptail --title "${title} — components" \
        --checklist "Select the components to include.${note}" \
        22 78 10 "${items[@]}" \
        3>&1 1>&2 2>&3) || { printf 'Cancelled.\n'; exit 0; }

    [[ "$picked" == *DRIVER*        ]] && ENABLE[driver]=1
    [[ "$picked" == *CUDA*          ]] && ENABLE[cuda]=1
    [[ "$picked" == *CTK*           ]] && ENABLE[ctk]=1
    [[ "$picked" == *CUDNN*         ]] && ENABLE[cudnn]=1
    [[ "$picked" == *NCCL*          ]] && ENABLE[nccl]=1
    [[ "$picked" == *DCGM*          ]] && ENABLE[dcgm]=1
    [[ "$picked" == *FABRICMANAGER* ]] && ENABLE[fabricmanager]=1
    [[ "$picked" == *DOCA*          ]] && ENABLE[doca]=1

    _select_resolve_dependencies
    _select_versions
}

# Components that cannot stand alone. Offer to drop them rather than failing
# halfway through collection.
_select_resolve_dependencies() {
    local pairs=(
        "fabricmanager:driver:Fabric Manager depends on the kernel modules the driver package supplies."
        "cudnn:cuda:cuDNN packages depend on CUDA."
        "nccl:cuda:NCCL packages depend on CUDA."
    )
    local entry child parent why
    for entry in "${pairs[@]}"; do
        child="${entry%%:*}"
        parent="$(printf '%s' "$entry" | cut -d: -f2)"
        why="${entry#*:*:}"
        if [ "${ENABLE[$child]}" -eq 1 ] && [ "${ENABLE[$parent]}" -eq 0 ]; then
            if whiptail --title "airgap-gpu" --yesno \
                "${child} is selected but ${parent} is not.\n\n${why}\n\nDrop ${child} and continue?" \
                13 74 3>&1 1>&2 2>&3; then
                ENABLE[$child]=0
            else
                printf 'Cancelled.\n'; exit 0
            fi
        fi
    done
}

_select_ask() {
    # $1 = key, $2 = prompt, $3 = regex
    local key="$1" prompt="$2" re="$3" value
    value=$(whiptail --title "airgap-gpu — ${key}" \
        --inputbox "$prompt" 12 74 "${VERSIONS[$key]}" \
        3>&1 1>&2 2>&3) || { printf 'Cancelled.\n'; exit 0; }
    [[ "$value" =~ $re ]] || die "Invalid ${key} version: ${value}"
    VERSIONS[$key]="$value"
}

_select_versions() {
    [ "${ENABLE[driver]}" -eq 1 ] && _select_ask driver \
        "GPU driver version\n\nFormat: X.Y.Z" '^[0-9]+\.[0-9]+\.[0-9]+$'
    [ "${ENABLE[cuda]}" -eq 1 ] && _select_ask cuda \
        "CUDA Toolkit version, hyphen form\n\n  13-2    latest patch in the 13.2 line\n  13-2-1  pin that exact patch" \
        '^[0-9]+-[0-9]+(-[0-9]+)?$'
    [ "${ENABLE[cudnn]}" -eq 1 ] && _select_ask cudnn \
        "cuDNN version\n\nFormat: X.Y.Z" '^[0-9]+\.[0-9]+\.[0-9]+$'
    [ "${ENABLE[nccl]}" -eq 1 ] && _select_ask nccl \
        "NCCL version\n\nFormat: X.Y.Z" '^[0-9]+\.[0-9]+\.[0-9]+$'
    [ "${ENABLE[dcgm]}" -eq 1 ] && _select_ask dcgm \
        "DCGM version\n\n  3.3.x  R535 and earlier only\n  4.x    R545 and newer" \
        '^[0-9]+\.[0-9]+\.[0-9]+$'
    [ "${ENABLE[doca]}" -eq 1 ] && _select_ask doca \
        "DOCA / OFED version\n\nFormat: X.Y.Z" '^[0-9]+\.[0-9]+\.[0-9]+$'
    [ "${ENABLE[ctk]}" -eq 1 ] && _select_ask ctk \
        "Container Toolkit version\n\nFormat: X.Y.Z" '^[0-9]+\.[0-9]+\.[0-9]+$'
    return 0
}

_select_derive() {
    local input="${VERSIONS[cuda]}"
    if [[ "$input" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]]; then
        CUDA_SERIES="${input%-*}"
        CUDA_PATCH="${CUDA_SERIES//-/.}.${input##*-}"
    else
        CUDA_SERIES="$input"
        CUDA_PATCH=""
    fi
    CUDA_MAJOR="${CUDA_SERIES%%-*}"
}

# DCGM major against driver branch.
#
#   DCGM 3.3.x  legacy `datacenter-gpu-manager`, R535 and earlier
#   DCGM 4.x    `datacenter-gpu-manager-4-cuda{12,13}`, R545 and newer
#
# Crossing that line fails at runtime, not at install: 3.3.x cannot initialise
# NVML against R545+, and 4.x fails on symbols missing from R535. Catching it
# here saves the operator a full build and transfer.
_select_validate() {
    [ "${ENABLE[dcgm]}" -eq 1 ] || return 0
    [ "${ENABLE[driver]}" -eq 1 ] || return 0

    local dcgm_major="${VERSIONS[dcgm]%%.*}"
    local drv_major="${VERSIONS[driver]%%.*}"
    local problem="" suggestion=""

    if [ "$dcgm_major" -eq 3 ] && [ "$drv_major" -ge 545 ]; then
        problem="DCGM ${VERSIONS[dcgm]} is for R535 and earlier; this build targets R${drv_major}."
        suggestion="4.6.0"
    elif [ "$dcgm_major" -ge 4 ] && [ "$drv_major" -le 535 ]; then
        problem="DCGM ${VERSIONS[dcgm]} requires R545 or newer; this build targets R${drv_major}."
        suggestion="3.3.9"
    else
        return 0
    fi

    if [ "${AIRGAP_GPU_NONINTERACTIVE:-0}" = "1" ]; then
        warn "  ${problem} Using ${suggestion}."
        VERSIONS[dcgm]="$suggestion"
        return 0
    fi

    if whiptail --title "airgap-gpu — DCGM compatibility" --yesno \
        "${problem}\n\nUse DCGM ${suggestion} instead?\n\nYes  use ${suggestion}\nNo   keep ${VERSIONS[dcgm]} anyway" \
        14 74 3>&1 1>&2 2>&3; then
        VERSIONS[dcgm]="$suggestion"
        log "  DCGM set to ${VERSIONS[dcgm]} for R${drv_major}."
    else
        warn "  Keeping DCGM ${VERSIONS[dcgm]} against R${drv_major} at the operator's direction."
    fi
}

_select_echo() {
    blank
    say "  Components"
    local key label
    for key in driver cuda ctk cudnn nccl dcgm fabricmanager doca; do
        if [ "${ENABLE[$key]}" -eq 1 ]; then
            label="${VERSIONS[$key]:-}"
            printf '    %-16s on   %s\n' "$key" "$label" | tee -a "$BUILD_LOG"
        fi
    done
    blank
}
