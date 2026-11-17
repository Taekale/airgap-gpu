#!/usr/bin/env bash
# lib/license.sh — Polar license key handling
#
# Licensing model
# ---------------
# The unit of licensing is the BUILD MACHINE, not the GPU node.
#
#     [build machine]   key validated -> collect -> bundle
#            |
#            |  tarball carried across the boundary
#            v
#     [air-gapped nodes]   no validation, unlimited installs
#
# This follows the deployment's own shape: the build host is necessarily
# online, and the targets are necessarily not. Node-count licensing would be
# unenforceable here and would fail procurement review in exactly the
# environments this tool exists for.
#
# A Polar license key's activation limit maps directly onto the tier's build
# machine count, and each build machine stores its activation id locally.
#
# Lapse behavior
# --------------
# A lapsed subscription does NOT disable the software. The operator keeps the
# version they have and stops receiving updates. That promise is the reason
# air-gapped operators will accept a subscription at all, so it is enforced
# here rather than left to documentation: validation failures after a
# successful activation downgrade to a warning.
#
# What activation does gate is the FIRST use. Without a successful activation
# on this machine, the Pro modules are never loaded.

: "${POLAR_API_BASE:=https://api.polar.sh/v1/customer-portal/license-keys}"

# Set at release time. POLAR_ORG_ID scopes keys to this organization — Polar
# requires it so that a valid key from another seller cannot be replayed here.
: "${POLAR_ORG_ID:=f99b9332-cffd-4297-959a-7bd96324b1da}"

# Benefit ids distinguish the tiers. A key is only honored for the tier whose
# benefit it carries.
: "${POLAR_BENEFIT_SOLO:=819e1d29-3db4-4e83-aeb2-6a59ed6ff477}"
: "${POLAR_BENEFIT_TEAM:=1d350829-750c-424a-8490-b3382b8087ba}"
: "${POLAR_BENEFIT_PARTNER:=3b639a3d-0ce1-4667-9de2-46e7aa6ee3dc}"

: "${LICENSE_STATE_DIR:=/etc/airgap-gpu}"
: "${LICENSE_STATE_FILE:=${LICENSE_STATE_DIR}/license.json}"

# How long a build may proceed on a previously-valid license when the Polar
# API cannot be reached. Build hosts sit behind corporate proxies and transient
# failures are routine; a network blip must not block a transfer window.
: "${LICENSE_OFFLINE_GRACE_DAYS:=30}"

LICENSE_TIER=""         # solo | team | partner
LICENSE_STATUS=""       # active | lapsed | grace | unlicensed
LICENSE_KEY=""
LICENSE_ACTIVATION_ID=""

_license_json_get() {
    # $1 = JSON text, $2 = dotted path. Prints the value or nothing.
    # python3 is present on every supported platform. -I isolates the
    # interpreter so nothing is imported from the working directory.
    printf '%s' "$1" | python3 -I -c '
import json,sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cur = doc
for part in sys.argv[1].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
if cur is None or isinstance(cur, (dict, list)):
    sys.exit(0)
print(cur)
' "$2" 2>/dev/null || true
}

_license_post() {
    # $1 = endpoint suffix, $2 = JSON body.
    # Prints "<http_status>\n<body>". Never fails the caller: an unreachable
    # API is a condition to handle, not an error to abort on.
    local suffix="$1" body="$2"
    curl -sS --max-time 20 \
        -w '\n%{http_code}' \
        -X POST "${POLAR_API_BASE}/${suffix}" \
        -H 'Content-Type: application/json' \
        -d "$body" 2>>"${BUILD_LOG:-/dev/null}" || true
}

_license_tier_for_benefit() {
    # Guard the empty case first. With the POLAR_BENEFIT_* values unset — an
    # unconfigured build — an empty benefit id would otherwise match the first
    # empty pattern below and silently grant a tier.
    [ -n "$1" ] || { printf ''; return; }
    case "$1" in
        "$POLAR_BENEFIT_PARTNER") printf 'partner' ;;
        "$POLAR_BENEFIT_TEAM")    printf 'team'    ;;
        "$POLAR_BENEFIT_SOLO")    printf 'solo'    ;;
        *)                        printf ''        ;;
    esac
}

_license_state_write() {
    mkdir -p "$LICENSE_STATE_DIR"
    umask 077
    cat > "$LICENSE_STATE_FILE" <<EOF
{
  "key": "${LICENSE_KEY}",
  "activation_id": "${LICENSE_ACTIVATION_ID}",
  "tier": "${LICENSE_TIER}",
  "last_valid": $(date +%s)
}
EOF
    chmod 0600 "$LICENSE_STATE_FILE"
}

_license_state_read() {
    [ -r "$LICENSE_STATE_FILE" ] || return 1
    local raw
    raw=$(cat "$LICENSE_STATE_FILE" 2>/dev/null) || return 1
    LICENSE_KEY=$(_license_json_get "$raw" key)
    LICENSE_ACTIVATION_ID=$(_license_json_get "$raw" activation_id)
    LICENSE_TIER=$(_license_json_get "$raw" tier)
    LICENSE_LAST_VALID=$(_license_json_get "$raw" last_valid)
    [ -n "$LICENSE_KEY" ]
}

# Register this build machine as one activation of the key.
# Run once per build host; the returned activation id is presented on every
# later validation so Polar can enforce the tier's machine count.
license_activate() {
    local key="$1"
    local label="${2:-$(hostname -s 2>/dev/null || printf 'build-host')}"

    [ -n "$POLAR_ORG_ID" ] || die "POLAR_ORG_ID is not configured in this build."

    log "Activating license on this build machine (${label})..."

    local resp status body
    resp=$(_license_post activate \
        "{\"key\":\"${key}\",\"organization_id\":\"${POLAR_ORG_ID}\",\"label\":\"${label}\"}")
    status=$(printf '%s' "$resp" | tail -n1)
    body=$(printf '%s' "$resp" | sed '$d')

    case "$status" in
        200|201)
            LICENSE_KEY="$key"
            LICENSE_ACTIVATION_ID=$(_license_json_get "$body" id)
            local benefit
            benefit=$(_license_json_get "$body" license_key.benefit_id)
            [ -z "$benefit" ] && benefit=$(_license_json_get "$body" benefit_id)
            LICENSE_TIER=$(_license_tier_for_benefit "$benefit")
            if [ -z "$LICENSE_TIER" ]; then
                die "This key is valid but belongs to a different product.
   Check that the key was issued for airgap-gpu Pro."
            fi
            _license_state_write
            log "  Activated. Tier: ${LICENSE_TIER}"
            return 0
            ;;
        403)
            die "Activation limit reached for this key.

   Each tier allows a fixed number of build machines:
     Solo     1
     Team     5
     Partner  1000

   Deactivate an old build host from the Polar customer portal, or move up a
   tier. Air-gapped TARGETS are never counted — only machines that build."
            ;;
        404)
            die "License key not found. Check for a transcription error, or
   confirm the key in the Polar customer portal."
            ;;
        "")
            die "Could not reach the licensing service to activate.

   Activation needs network access once, from this build machine. Subsequent
   builds tolerate the service being unreachable; the first one cannot."
            ;;
        *)
            die "Activation failed (HTTP ${status}). See ${BUILD_LOG:-the build log}."
            ;;
    esac
}

# Check the stored license. Prints status; never aborts for a lapse.
license_check() {
    if ! _license_state_read; then
        LICENSE_STATUS="unlicensed"
        return 1
    fi

    local payload="{\"key\":\"${LICENSE_KEY}\",\"organization_id\":\"${POLAR_ORG_ID}\""
    [ -n "$LICENSE_ACTIVATION_ID" ] && \
        payload="${payload},\"activation_id\":\"${LICENSE_ACTIVATION_ID}\""
    payload="${payload}}"

    local resp status body
    resp=$(_license_post validate "$payload")
    status=$(printf '%s' "$resp" | tail -n1)
    body=$(printf '%s' "$resp" | sed '$d')

    case "$status" in
        200)
            local key_status
            key_status=$(_license_json_get "$body" status)
            if [ "$key_status" = "granted" ] || [ -z "$key_status" ]; then
                LICENSE_STATUS="active"
                _license_state_write          # refresh last_valid
                return 0
            fi
            LICENSE_STATUS="lapsed"
            return 0
            ;;
        403|404)
            # Definitively rejected. The operator keeps the version they have.
            LICENSE_STATUS="lapsed"
            return 0
            ;;
        *)
            # Unreachable. Fall back to the grace window.
            local now age_days
            now=$(date +%s)
            age_days=$(( (now - ${LICENSE_LAST_VALID:-0}) / 86400 ))
            if [ "$age_days" -le "$LICENSE_OFFLINE_GRACE_DAYS" ]; then
                LICENSE_STATUS="grace"
            else
                LICENSE_STATUS="lapsed"
            fi
            return 0
            ;;
    esac
}

# Report the licensing position in one line, and say what it means for
# this build. Called once, before module loading.
license_report() {
    case "$LICENSE_STATUS" in
        active)
            log "License: ${LICENSE_TIER} tier, active."
            ;;
        grace)
            warn "License: could not reach the licensing service; continuing on"
            warn "  the last successful check (within the ${LICENSE_OFFLINE_GRACE_DAYS}-day grace window)."
            ;;
        lapsed)
            warn "License: subscription is not currently active."
            warn "  This build proceeds with the modules already on this machine."
            warn "  You will not receive matrix or rule updates until it is renewed."
            ;;
        unlicensed)
            log "License: none. Building with the free driver path only."
            ;;
    esac
}

# True when Pro modules may be loaded. Activation is the gate, not currency:
# a lapsed key still carries its last delivered modules.
license_pro_enabled() {
    case "$LICENSE_STATUS" in
        active|grace|lapsed) return 0 ;;
        *)                   return 1 ;;
    esac
}

# Release this build machine's activation so the seat can be reused.
license_deactivate() {
    _license_state_read || die "No license is registered on this machine."
    local resp status
    resp=$(_license_post deactivate \
        "{\"key\":\"${LICENSE_KEY}\",\"organization_id\":\"${POLAR_ORG_ID}\",\"activation_id\":\"${LICENSE_ACTIVATION_ID}\"}")
    status=$(printf '%s' "$resp" | tail -n1)
    case "$status" in
        200|204)
            rm -f "$LICENSE_STATE_FILE"
            log "Deactivated. This build machine's seat has been released."
            ;;
        *)
            die "Deactivation failed (HTTP ${status}). Release the seat from the
   Polar customer portal instead."
            ;;
    esac
}
