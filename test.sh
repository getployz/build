#!/usr/bin/env bash
# Runs prepare.sh and build.sh against stubbed curl, docker, sudo and ployz.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs" "$tmp/runner" "$tmp/workspace"

commit=0123456789abcdef0123456789abcdef01234567
fingerprint=$(printf 'f%.0s' {1..64})
cat >"$tmp/check-in.json" <<JSON
{"grant":"ployzgrant1:grant-secret","commit":"$commit","fingerprint":"$fingerprint","ployzVersion":"0.1.0-beta.28",
 "deployment":{"projectName":"p","snapshots":[{"config":{},"resolvedEnv":{"TOKEN":"s3cr3t","KEY":"line-one\nline-two","PORT":"0","ABC":"abc"}}]}}
JSON

cat >"$tmp/stubs/curl" <<STUB
#!/usr/bin/env bash
out=; url=; status=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift ;; -w) status=200; shift ;; --data-binary) cat "\${2#@}" >>"$tmp/posted.jsonl"; shift ;; -H|-X) shift ;; -*) ;; *) url=\$1 ;; esac
  shift
done
case "\$url" in
  https://ployz.sh) if [ -n "\${INSTALL_FAIL:-}" ]; then echo "curl: (22) 404" >&2; exit 22; fi; printf '%s\n' 'mkdir -p "\$INSTALL_BIN_DIR"; echo "\$PLOYZ_VERSION" > "$tmp/installed"; : > "\$INSTALL_BIN_DIR/ployz"; chmod +x "\$INSTALL_BIN_DIR/ployz"' > "\$out" ;;
  *audience=https%3A%2F%2Fcloud.test) echo '{"value":"oidc-token"}' ;;
  https://cloud.test/api/builds/b-1/check-in)
    echo >>"$tmp/check-ins"
    # CHECK_IN=unreachable: the first try can't connect. CHECK_IN=refused: Cloud answers 409.
    # CHECK_IN=bad-version: Cloud names a ployz version that isn't a release tag.
    if [ "\${CHECK_IN:-}" = unreachable ] && [ "\$(wc -l <"$tmp/check-ins")" = 1 ]; then echo "curl: (7) Failed to connect" >&2; exit 7; fi
    if [ "\${CHECK_IN:-}" = refused ]; then
      echo '{"_tag":"PublicError","code":"CONFLICT","message":"This build already started or is no longer wanted."}' >"\$out"; status=409
    elif [ "\${CHECK_IN:-}" = bad-version ]; then jq '.ployzVersion = "0.1.0; curl evil.test"' "$tmp/check-in.json" >"\$out"
    else cp "$tmp/check-in.json" "\$out"; fi ;;
  https://cloud.test/api/builds/b-1/steps) echo '{}' >"\$out" ;;
  *) echo "unexpected curl \$url" >&2; exit 1 ;;
esac
printf '%s' "\$status"
STUB
cat >"$tmp/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo '[["driver-type","io.containerd.snapshotter.v1"]]'
STUB
cat >"$tmp/stubs/ployz" <<STUB
#!/usr/bin/env bash
[ "\$PLOYZ_BUILD_GRANT" = ployzgrant1:grant-secret ] || { echo "grant not exported" >&2; exit 1; }
[ "\$*" = "build --deployment $tmp/runner/ployz-build/deployment.json --commit $commit --fingerprint $fingerprint --source $tmp/workspace --events $tmp/runner/ployz-build/events.jsonl" ] || { echo "bad args: \$*" >&2; exit 1; }
events=$tmp/runner/ployz-build/events.jsonl
printf '%s\n' '{"at":1,"event":{"Build":{"Stage":"Building"}}}' '{"at":2,"event":{"Build":{"Stage":"Output"}}}' >>"\$events"
# Long enough for a report while the build runs.
sleep 0.5
echo '{"at":3,"event":{"Build":{"Stage":"Cleanup"}}}' >>"\$events"
[ -z "\${PLOYZ_FAIL:-}" ] || exit 3
echo '{"digest":"sha256:abc","tag":"ployz-sha256-abc","platforms":["linux/amd64"]}'
# The build cache export, after the push: Cloud has the final report before it ends.
rm -f "$tmp/reported-during-export"
sleep 0.5
jq -se 'any(.[]; has("platforms"))' "$tmp/posted.jsonl" >/dev/null && : >"$tmp/reported-during-export"
# A failed export is only a warning.
[ -z "\${PLOYZ_EXPORT_FAIL:-}" ] || echo "warning: the image was pushed, but its build cache was not exported" >&2
STUB
chmod +x "$tmp/stubs/"*

export PATH="$tmp/stubs:$PATH" RUNNER_TEMP="$tmp/runner" GITHUB_WORKSPACE="$tmp/workspace"
export GITHUB_OUTPUT="$tmp/output" GITHUB_PATH="$tmp/path" GITHUB_STEP_SUMMARY="$tmp/summary"
export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.test/?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
export PLOYZ_BUILD_ID=b-1 PLOYZ_CLOUD=https://cloud.test/ PLOYZ_STEPS_INTERVAL=0.1

log=$("$here/prepare.sh")
for mask in oidc-token ployzgrant1:grant-secret s3cr3t line-one line-two; do
  grep -qxF "::add-mask::$mask" <<<"$log" || { echo "FAIL: $mask not masked" >&2; exit 1; }
done
# Values under 4 characters aren't masked: masking `0` would turn HTTP 404 into 4***4.
for short in 0 abc; do
  if grep -qxF "::add-mask::$short" <<<"$log"; then echo "FAIL: short value $short masked" >&2; exit 1; fi
done
grep -qxF "commit=$commit" "$GITHUB_OUTPUT" || { echo "FAIL: commit output" >&2; exit 1; }
jq -e '.snapshots[0].resolvedEnv.TOKEN == "s3cr3t"' "$RUNNER_TEMP/ployz-build/deployment.json" >/dev/null
[ -x "$(cat "$GITHUB_PATH")/ployz" ] || { echo "FAIL: ployz not installed" >&2; exit 1; }
# The version the check-in named, not one the workflow chose.
[ "$(cat "$tmp/installed")" = 0.1.0-beta.28 ] || { echo "FAIL: installed $(cat "$tmp/installed"), not the check-in's version" >&2; exit 1; }

"$here/build.sh" >/dev/null
grep -qxF "digest=sha256:abc" "$GITHUB_OUTPUT" || { echo "FAIL: digest output" >&2; exit 1; }
# Steps go to Cloud while the build runs, each batch from where the last one ended; the last carries the platforms.
# shellcheck disable=SC2016 # jq variables, not shell ones
reported='length >= 2 and .[0].from == 0 and (.[0] | has("platforms") | not)
  and ([.[].events[].at][1:] == [1, 2, 3]) and .[0].events[0].event.Build.Step.name == "Installing ployz" and (. as $b | all(range(1; $b | length); $b[.].from == $b[. - 1].from + ($b[. - 1].events | length)))'
jq -s -e "$reported"' and .[-1].platforms == ["linux/amd64"]' "$tmp/posted.jsonl" >/dev/null ||
  { echo "FAIL: Build Steps not posted as they happened" >&2; cat "$tmp/posted.jsonl" >&2; exit 1; }
[ -e "$tmp/reported-during-export" ] || { echo "FAIL: the final report waited for the cache export" >&2; exit 1; }
# A failed cache export still passes the job, whose report went when the image was pushed.
rm "$tmp/posted.jsonl" "$GITHUB_OUTPUT"
PLOYZ_EXPORT_FAIL=1 "$here/build.sh" >/dev/null 2>&1 || { echo "FAIL: a failed cache export failed the job" >&2; exit 1; }
[ -e "$tmp/reported-during-export" ] || { echo "FAIL: the final report waited for a failing cache export" >&2; exit 1; }
jq -s -e "$reported"' and .[-1].platforms == ["linux/amd64"]' "$tmp/posted.jsonl" >/dev/null ||
  { echo "FAIL: a failed cache export changed the report" >&2; cat "$tmp/posted.jsonl" >&2; exit 1; }
grep -qxF "digest=sha256:abc" "$GITHUB_OUTPUT" || { echo "FAIL: digest output after a failed cache export" >&2; exit 1; }
# A failed build still reports its steps, then fails the job.
rm "$tmp/posted.jsonl"
if PLOYZ_FAIL=1 "$here/build.sh" >/dev/null 2>&1; then echo "FAIL: a failed build passed" >&2; exit 1; fi
jq -s -e "$reported"' and .[-1].platforms == []' "$tmp/posted.jsonl" >/dev/null || { echo "FAIL: a failed build did not report" >&2; exit 1; }

# A check-in that can't reach Cloud is retried; one Cloud refuses is not, and the job shows why.
rm -f "$tmp/check-ins"
CHECK_IN=unreachable "$here/prepare.sh" >/dev/null 2>&1 || { echo "FAIL: an unreachable check-in was not retried" >&2; exit 1; }
[ "$(wc -l <"$tmp/check-ins")" = 2 ] || { echo "FAIL: check-in tries after a connection failure" >&2; exit 1; }
rm "$tmp/check-ins"
if log=$(CHECK_IN=refused "$here/prepare.sh" 2>&1); then echo "FAIL: a refused check-in passed" >&2; exit 1; fi
grep -qF "::error::Ployz Cloud refused the check-in for build b-1 (HTTP 409: This build already started or is no longer wanted.)" <<<"$log" ||
  { echo "FAIL: a refused check-in did not print Cloud's answer" >&2; echo "$log" >&2; exit 1; }
[ "$(wc -l <"$tmp/check-ins")" = 1 ] || { echo "FAIL: a refused check-in was retried" >&2; exit 1; }

# A failed install tells Cloud, naming the version, so Cloud moves the build on; the job fails.
rm -f "$tmp/posted.jsonl"
if log=$(INSTALL_FAIL=1 "$here/prepare.sh" 2>&1); then echo "FAIL: a failed install passed" >&2; exit 1; fi
jq -s -e 'length == 1 and (.[0] | .from == 0 and .platforms == [] and .installFailed == "0.1.0-beta.28"
  and (.events | length == 1 and .[0].event.Build.Step.error == "Could not install ployz 0.1.0-beta.28."))' "$tmp/posted.jsonl" >/dev/null ||
  { echo "FAIL: a failed install did not report" >&2; cat "$tmp/posted.jsonl" >&2; exit 1; }
grep -qxF "::error::Could not install ployz 0.1.0-beta.28." <<<"$log" || { echo "FAIL: a failed install did not say why" >&2; echo "$log" >&2; exit 1; }

rm "$tmp/installed"
if CHECK_IN=bad-version "$here/prepare.sh" >/dev/null 2>&1; then echo "FAIL: accepted a malformed ployz version" >&2; exit 1; fi
[ ! -e "$tmp/installed" ] || { echo "FAIL: installed a malformed ployz version" >&2; exit 1; }
if PLOYZ_CLOUD=https://evil.test/path "$here/prepare.sh" >/dev/null 2>&1; then echo "FAIL: accepted a Cloud URL with a path" >&2; exit 1; fi
echo "ok"
