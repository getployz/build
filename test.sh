#!/usr/bin/env bash
# Runs prepare.sh and build.sh against stubbed curl, docker, sudo and ployz.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs" "$tmp/runner" "$tmp/workspace"

build=00000000-0000-4000-8000-00000000b101.web
commit=0123456789abcdef0123456789abcdef01234567
fingerprint=$(printf 'f%.0s' {1..64})
machine=$(printf '01%.0s' {1..32})
cat >"$tmp/check-in.json" <<JSON
{"grant":"ployzgrant1:grant-secret","commit":"$commit","fingerprint":"$fingerprint","ployzVersion":"0.1.0-beta.28",
 "deployment":{"projectName":"p","snapshots":[{"config":{},"resolvedEnv":{"TOKEN":"s3cr3t","KEY":"line-one\nline-two","PORT":"0","ABC":"abc"}}]}}
JSON

cat >"$tmp/stubs/curl" <<STUB
#!/usr/bin/env bash
out=; url=; status=; data=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift ;; -w) status=200; shift ;; --data-binary) data=\${2#@}; shift ;; -H|-X) shift ;; -*) ;; *) url=\$1 ;; esac
  shift
done
case "\$url" in
  https://ployz.sh) if [ -n "\${INSTALL_FAIL:-}" ]; then echo "curl: (22) 404" >&2; exit 22; fi; printf '%s\n' 'mkdir -p "\$INSTALL_BIN_DIR"; echo "\$PLOYZ_VERSION" > "$tmp/installed"; : > "\$INSTALL_BIN_DIR/ployz"; chmod +x "\$INSTALL_BIN_DIR/ployz"' > "\$out" ;;
  *audience=https%3A%2F%2Fcloud.test) echo '{"value":"oidc-token"}' ;;
  https://cloud.test/api/builds/$build/check-in)
    echo >>"$tmp/check-ins"
    cp "\$data" "$tmp/check-in-body.json"
    # CHECK_IN=unreachable: the first try can't connect. CHECK_IN=refused: Cloud answers 409.
    # CHECK_IN=bad-version: Cloud names a ployz version that isn't a release tag.
    # CHECK_IN=holder: the Machine minted for the holder, so Cloud sends the Machine, not the grant.
    if [ "\${CHECK_IN:-}" = unreachable ] && [ "\$(wc -l <"$tmp/check-ins")" = 1 ]; then echo "curl: (7) Failed to connect" >&2; exit 7; fi
    if [ "\${CHECK_IN:-}" = refused ]; then
      echo '{"_tag":"PublicError","code":"CONFLICT","message":"This build already started or is no longer wanted."}' >"\$out"; status=409
    elif [ "\${CHECK_IN:-}" = bad-version ]; then jq '.ployzVersion = "0.1.0; curl evil.test"' "$tmp/check-in.json" >"\$out"
    elif [ "\${CHECK_IN:-}" = holder ]; then jq --arg machine "$machine" 'del(.grant) + {machine: \$machine}' "$tmp/check-in.json" >"\$out"
    else cp "$tmp/check-in.json" "\$out"; fi ;;
  https://cloud.test/api/builds/$build/steps) cat "\$data" >>"$tmp/posted.jsonl"; echo '{}' >"\$out" ;;
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
[ "\$PLOYZ_BUILD_GRANT" = "\${GRANT:-ployzgrant1:grant-secret}" ] || { echo "grant not exported" >&2; exit 1; }
[ "\$*" = "build --deployment $tmp/runner/ployz-build/deployment.json --commit $commit --fingerprint $fingerprint --source $tmp/workspace --events $tmp/runner/ployz-build/events.jsonl" ] || { echo "bad args: \$*" >&2; exit 1; }
[ "\$TMPDIR" = $tmp/runner/ployz-build/tmp ] && [ "\$(stat -c %a "\$TMPDIR")" = 700 ] || { echo "TMPDIR is not the work dir's" >&2; exit 1; }
events=$tmp/runner/ployz-build/events.jsonl
# PLOYZ_HANG: a build still running, an opened Sealed value in its scratch, when the job is cancelled.
# PLOYZ_HANG=1 dies on TERM. PLOYZ_HANG=graceful takes a moment to stop, then notes whether the key is still there.
if [ -n "\${PLOYZ_HANG:-}" ]; then
  mkdir -p "\$TMPDIR/ployz-build-1/private/sealed" && echo sealed-value >"\$TMPDIR/ployz-build-1/private/sealed/TOKEN"
  echo "\$\$" >"$tmp/ployz.pid"
  [ "\$PLOYZ_HANG" = graceful ] || exec sleep 30
  trap 'kill \$!; sleep 0.3; [ -e "$tmp/runner/ployz-build/key" ] && : >"$tmp/stopped-with-key"; exit 143' TERM
  sleep 30 & wait
fi
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
export PLOYZ_BUILD_ID=$build PLOYZ_CLOUD=https://cloud.test/ PLOYZ_STEPS_INTERVAL=0.1

log=$("$here/prepare.sh")
for mask in oidc-token ployzgrant1:grant-secret s3cr3t line-one line-two; do
  grep -qxF "::add-mask::$mask" <<<"$log" || { echo "FAIL: $mask not masked" >&2; exit 1; }
done
# Values under 4 characters aren't masked: masking `0` would turn HTTP 404 into 4***4.
for short in 0 abc; do
  if grep -qxF "::add-mask::$short" <<<"$log"; then echo "FAIL: short value $short masked" >&2; exit 1; fi
done
grep -qxF "commit=$commit" "$GITHUB_OUTPUT" || { echo "FAIL: commit output" >&2; exit 1; }
# The legacy grant, minted by Cloud, opens no Sealed values; the job says which grant it used.
grep -qxF "::notice::This build used a Cloud-held Build Grant." <<<"$log" || { echo "FAIL: a Cloud-held grant went unnoticed" >&2; exit 1; }
# The Build Grant key stays on the runner, readable only by its user; Cloud gets the holder.
key=$RUNNER_TEMP/ployz-build/key
[ "$(stat -c %a "$key")" = 600 ] || { echo "FAIL: the key file is not 0600" >&2; exit 1; }
[ "$(jq -r '.holder' "$tmp/check-in-body.json")" = "$(node "$here/grant.js" holder "$key")" ] ||
  { echo "FAIL: the check-in did not carry the holder" >&2; exit 1; }
grep -qE '^[0-9a-f]{64}$' <(jq -r '.holder' "$tmp/check-in-body.json") || { echo "FAIL: holder is not 64 hex" >&2; exit 1; }
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
[ ! -e "$RUNNER_TEMP/ployz-build" ] || { echo "FAIL: the work dir outlived the build" >&2; exit 1; }
# A failed cache export still passes the job, whose report went when the image was pushed.
"$here/prepare.sh" >/dev/null
rm "$tmp/posted.jsonl" "$GITHUB_OUTPUT"
PLOYZ_EXPORT_FAIL=1 "$here/build.sh" >/dev/null 2>&1 || { echo "FAIL: a failed cache export failed the job" >&2; exit 1; }
[ -e "$tmp/reported-during-export" ] || { echo "FAIL: the final report waited for a failing cache export" >&2; exit 1; }
jq -s -e "$reported"' and .[-1].platforms == ["linux/amd64"]' "$tmp/posted.jsonl" >/dev/null ||
  { echo "FAIL: a failed cache export changed the report" >&2; cat "$tmp/posted.jsonl" >&2; exit 1; }
grep -qxF "digest=sha256:abc" "$GITHUB_OUTPUT" || { echo "FAIL: digest output after a failed cache export" >&2; exit 1; }
# A failed build still reports its steps, then fails the job.
"$here/prepare.sh" >/dev/null
rm "$tmp/posted.jsonl"
if PLOYZ_FAIL=1 "$here/build.sh" >/dev/null 2>&1; then echo "FAIL: a failed build passed" >&2; exit 1; fi
jq -s -e "$reported"' and .[-1].platforms == []' "$tmp/posted.jsonl" >/dev/null || { echo "FAIL: a failed build did not report" >&2; exit 1; }

# A check-in that can't reach Cloud is retried; one Cloud refuses is not, and the job shows why.
rm -f "$tmp/check-ins"
CHECK_IN=unreachable "$here/prepare.sh" >/dev/null 2>&1 || { echo "FAIL: an unreachable check-in was not retried" >&2; exit 1; }
[ "$(wc -l <"$tmp/check-ins")" = 2 ] || { echo "FAIL: check-in tries after a connection failure" >&2; exit 1; }
rm "$tmp/check-ins"
if log=$(CHECK_IN=refused "$here/prepare.sh" 2>&1); then echo "FAIL: a refused check-in passed" >&2; exit 1; fi
grep -qF "::error::Ployz Cloud refused the check-in for build $build (HTTP 409: This build already started or is no longer wanted.)" <<<"$log" ||
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
for id in . .. ../x a/b "a b" "$(printf 'a%.0s' {1..129})"; do
  if log=$(PLOYZ_BUILD_ID=$id "$here/prepare.sh" 2>&1); then echo "FAIL: accepted build id $id" >&2; exit 1; fi
  grep -qxF "::error::Invalid build id." <<<"$log" || { echo "FAIL: build id $id not refused as invalid" >&2; echo "$log" >&2; exit 1; }
done
if PLOYZ_CLOUD=https://evil.test/path "$here/prepare.sh" >/dev/null 2>&1; then echo "FAIL: accepted a Cloud URL with a path" >&2; exit 1; fi

# RFC 8032 test 1: the seed's public key is the holder Cloud mints for.
node -e 'require("fs").writeFileSync(process.argv[1], Buffer.from(process.argv[2], "hex"))' "$tmp/fixture.key" \
  9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
[ "$(node "$here/grant.js" holder "$tmp/fixture.key")" = d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a ] ||
  { echo "FAIL: holder of the RFC 8032 seed" >&2; exit 1; }
jq -n --arg machine "$machine" '{machine: $machine}' >"$tmp/fixture.json"
fixture=ployzgrant1:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQGdYbGd7_1aYLqESvSS7CzEREnFaXsyaRlwO6wDHK5_YA
[ "$(node "$here/grant.js" assemble "$tmp/fixture.json" "$tmp/fixture.key" "$tmp/fixture.grant")" = "::add-mask::$fixture" ] ||
  { echo "FAIL: the assembled grant was not masked" >&2; exit 1; }
[ "$(cat "$tmp/fixture.grant")" = "$fixture" ] || { echo "FAIL: assembled grant" >&2; exit 1; }
# A key or grant file already there, readable by others, ends up 0600 all the same.
for file in fixture.grant fresh.key; do echo stale >"$tmp/$file"; chmod 644 "$tmp/$file"; done
(umask 022; node "$here/grant.js" assemble "$tmp/fixture.json" "$tmp/fixture.key" "$tmp/fixture.grant" >/dev/null)
(umask 022; node "$here/grant.js" key "$tmp/fresh.key" >/dev/null)
for file in fixture.grant fresh.key; do
  [ "$(stat -c %a "$tmp/$file")" = 600 ] || { echo "FAIL: $file is not 0600 after a rewrite" >&2; exit 1; }
done
[ "$(stat -c %s "$tmp/fresh.key")" = 32 ] || { echo "FAIL: the new key is not a 32-byte seed" >&2; exit 1; }
# A key that is not a 32-byte seed is refused with a fixed line; no grant is written.
head -c 31 "$tmp/fixture.key" >"$tmp/short.key"
rm "$tmp/fixture.grant"
for command in "assemble $tmp/fixture.json $tmp/short.key $tmp/fixture.grant" "holder $tmp/short.key"; do
  # shellcheck disable=SC2086 # the command's words
  if log=$(node "$here/grant.js" $command); then echo "FAIL: accepted a 31-byte key ($command)" >&2; exit 1; fi
  [ "$log" = "::error::The Build Grant key is not 32 bytes." ] || { echo "FAIL: a 31-byte key refused as: $log" >&2; exit 1; }
done
[ ! -e "$tmp/fixture.grant" ] || { echo "FAIL: wrote a grant from a 31-byte key" >&2; exit 1; }
jq -n '{machine: "not hex"}' >"$tmp/fixture.json"
if node "$here/grant.js" assemble "$tmp/fixture.json" "$tmp/fixture.key" "$tmp/fixture.grant" >/dev/null 2>&1; then
  echo "FAIL: assembled a grant for a malformed Machine" >&2; exit 1
fi

# A Machine that minted for the holder: the runner assembles the grant from its own key, masked first.
log=$(CHECK_IN=holder "$here/prepare.sh")
grant="ployzgrant1:$({ printf '\1%.0s' {1..32}; cat "$key"; } | base64 -w0 | tr '+/' '-_' | tr -d =)"
[ "$(head -n 2 <<<"$log" | tail -n 1)" = "::add-mask::$grant" ] || { echo "FAIL: the assembled grant was not masked first" >&2; echo "$log" >&2; exit 1; }
if grep -qF "::notice::" <<<"$log"; then echo "FAIL: a runner-held grant was noticed as Cloud-held" >&2; exit 1; fi
rm "$tmp/posted.jsonl"
GRANT=$grant "$here/build.sh" >/dev/null || { echo "FAIL: build with the assembled grant" >&2; exit 1; }
jq -s -e "$reported"' and .[-1].platforms == ["linux/amd64"]' "$tmp/posted.jsonl" >/dev/null || { echo "FAIL: build with the assembled grant did not report" >&2; exit 1; }

# A cancelled job stops the build and waits for it before the work dir, the key and the build's scratch in it, goes.
cancel() {
  "$here/prepare.sh" >/dev/null
  rm -f "$tmp/ployz.pid" "$tmp/stopped-with-key"
  PLOYZ_HANG=$1 "$here/build.sh" >/dev/null 2>&1 &
  local runner=$! status=0
  for _ in {1..50}; do [ -s "$tmp/ployz.pid" ] && break; sleep 0.1; done
  [ -s "$tmp/ployz.pid" ] || { echo "FAIL: the hanging build did not start ($1)" >&2; exit 1; }
  kill -TERM "$runner"
  SECONDS=0
  wait "$runner" || status=$?
  [ "$SECONDS" -lt 5 ] || { echo "FAIL: a cancelled job did not stop the build ($1)" >&2; exit 1; }
  [ "$status" = 143 ] || { echo "FAIL: a cancelled build exited $status ($1)" >&2; exit 1; }
  if kill -0 "$(cat "$tmp/ployz.pid")" 2>/dev/null; then echo "FAIL: the build outlived the cancelled job ($1)" >&2; exit 1; fi
  [ ! -e "$RUNNER_TEMP/ployz-build" ] || { echo "FAIL: the work dir outlived the cancelled job ($1)" >&2; exit 1; }
}
cancel 1
cancel graceful
[ -e "$tmp/stopped-with-key" ] || { echo "FAIL: the key went before the build stopped" >&2; exit 1; }
echo "ok"
