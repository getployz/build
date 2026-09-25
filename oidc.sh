# shellcheck shell=bash
# Sourced by prepare.sh and build.sh.

# Sets $token to a fresh GitHub OIDC token whose audience is the Cloud origin $1, masked in the log.
oidc_token() {
    local audience
    audience=$(jq -rn --arg value "$1" '$value | @uri')
    token=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience" | jq -r '.value')
    echo "::add-mask::$token"
}

# POSTs to Cloud URL $1 with this run's $token, writing the response to $2; the rest are curl args.
# Retries only while Cloud can't be reached. An HTTP error is Cloud's answer, so it is final: sets
# $cloud_error to the status and Cloud's message, and returns 1.
# shellcheck disable=SC2034 # the caller reads $cloud_error
cloud_post() {
    local url=$1 out=$2 status message attempt
    shift 2
    for attempt in 1 2 3 4; do
        if status=$(curl -sS -X POST -H "Authorization: Bearer $token" -o "$out" -w '%{http_code}' "$@" "$url"); then
            [[ $status == 2?? ]] && return 0
            message=$(jq -er '.message' "$out" 2>/dev/null) || message=$(head -c 500 "$out")
            cloud_error="HTTP $status: $message"
            return 1
        fi
        [[ $attempt == 4 ]] || sleep "$attempt"
    done
    cloud_error="could not reach Ployz Cloud at $url"
    return 1
}
