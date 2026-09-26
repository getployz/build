#!/usr/bin/env bash
# Readies Docker, checks in with Ployz Cloud, then installs the ployz version the check-in names. Runs before checkout.
set -euo pipefail

# shellcheck source=oidc.sh
source "$(dirname "$0")/oidc.sh"
work="$RUNNER_TEMP/ployz-build"
fail() {
    echo "::error::$1"
    exit 1
}

[[ "$(uname -s)" == Linux ]] || fail "Ployz builds need a Linux runner."
[[ "$PLOYZ_BUILD_ID" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || fail "Invalid build id."
cloud=${PLOYZ_CLOUD%/}
[[ "$cloud" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || fail "Invalid Cloud URL; expected an origin like https://ployz.dev."
[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] || fail "The workflow needs 'permissions: id-token: write'."

umask 077
mkdir -p "$work/bin"

# ployz-build refuses Docker without the containerd image store; GitHub's hosted runners ship without it.
has_containerd_store() {
    docker info --format '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter.v1'
}
if ! has_containerd_store; then
    echo "Enabling Docker's containerd image store"
    config=/etc/docker/daemon.json
    if sudo test -s "$config"; then sudo cat "$config"; else echo '{}'; fi |
        jq '.features["containerd-snapshotter"] = true' >"$work/daemon.json"
    sudo install -m 0644 "$work/daemon.json" "$config"
    sudo systemctl restart docker
    has_containerd_store || fail "Docker's containerd image store could not be enabled."
fi

# GitHub's OIDC token proves this run to Cloud; its audience is the Cloud origin.
oidc_token "$cloud"

cloud_post "$cloud/api/builds/$PLOYZ_BUILD_ID/check-in" "$work/check-in.json" ||
    fail "Ployz Cloud refused the check-in for build $PLOYZ_BUILD_ID ($cloud_error)."

# Mask the grant and every build secret before anything can print them. Masks are per line.
# Lines under 4 characters stay visible: masking a value like `0` would star out every 0 in the log.
jq -r '.grant, (.deployment.snapshots[]?.resolvedEnv // {} | .[])' "$work/check-in.json" |
    while IFS= read -r line; do
        if [[ ${#line} -ge 4 ]]; then echo "::add-mask::$line"; fi
    done

jq -e '.grant | type == "string" and startswith("ployzgrant1:")' "$work/check-in.json" >/dev/null ||
    fail "Check-in response has no Build Grant."
commit=$(jq -r '.commit' "$work/check-in.json")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "Check-in response has no commit."
[[ "$(jq -r '.fingerprint' "$work/check-in.json")" =~ ^[0-9a-f]{64}$ ]] ||
    fail "Check-in response has no fingerprint."
jq -e '.deployment | objects' "$work/check-in.json" >"$work/deployment.json" ||
    fail "Check-in response has no deployment."
version=$(jq -r '.ployzVersion' "$work/check-in.json")
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.(0|[1-9][0-9]*))?$ ]] ||
    fail "Check-in response has no valid ployz version."

# The exact version that computed the fingerprint: during a Cloud rollout, the Cloud that
# dispatched this build may run another version than the one that answered the check-in.
# The install is the first Build Step, timed here where it runs, as a `ployz build --events` line:
# build.sh reports it ahead of the build's own. $1: why it failed.
install_started=$(date -u +%FT%T.%3NZ)
install_step() {
    jq -cn --argjson at "$(date +%s%3N)" --arg started "$install_started" --arg completed "$(date -u +%FT%T.%3NZ)" --arg error "${1:-}" \
        '{at: $at, event: {Build: {Step: {id: "install", name: "Installing ployz", started: $started, completed: $completed,
            cached: false, error: (if $error == "" then null else $error end)}}}}' >"$work/install.jsonl"
}
# A failed install never reaches build.sh, so its final report goes from here, naming the version:
# Cloud then moves the build on to the next Builder instead of waiting for the run to end.
install_failed() {
    install_step "Could not install ployz $version."
    jq -n --arg version "$version" --slurpfile events "$work/install.jsonl" \
        '{from: 0, events: $events, platforms: [], installFailed: $version}' >"$work/steps.json"
    oidc_token "$cloud"
    cloud_post "$cloud/api/builds/$PLOYZ_BUILD_ID/steps" "$work/steps-response.json" \
        -H "Content-Type: application/json" --data-binary "@$work/steps.json" ||
        echo "::warning::Ployz Cloud did not accept the report ($cloud_error)."
    fail "Could not install ployz $version."
}
curl -fsSL https://ployz.sh -o "$work/install.sh" || install_failed
PLOYZ_VERSION="$version" INSTALL_BIN_DIR="$work/bin" sh "$work/install.sh" || install_failed
install_step
echo "$work/bin" >>"$GITHUB_PATH"

echo "commit=$commit" >>"$GITHUB_OUTPUT"
