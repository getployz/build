# getployz/build

Builds one Ployz Image Build on a GitHub Actions runner and pushes the image into the Machine that Ployz Cloud chose. Cloud starts it; nothing runs on push.

## Set up

Commit [`ployz-build.yml`](ployz-build.yml) to the default branch as `.github/workflows/ployz-build.yml`. Ployz Cloud's **Add workflow** button opens GitHub's new-file page with it filled in. Keep it exactly as is: Cloud dispatches its inputs.

The GitHub App needs **Actions: write** and **Contents: read**, plus the **Push** and **Workflow run** events.

## Dispatch inputs

| Input | Set by Cloud to |
| --- | --- |
| `build` | Image Build id (`[A-Za-z0-9_-]`, up to 128 characters) |
| `cloud` | Cloud origin, for example `https://ployz.dev`. It is also the OIDC audience. |
| `runner` | The native runner for the one platform the Service needs: `ubuntu-latest` (amd64) or `ubuntu-24.04-arm` (arm64) |

Inputs are visible in GitHub, so none of them is secret.

## What it does

1. Exports the Actions cache runtime (`crazy-max/ghaction-github-runtime`), so `ployz build` uses the GitHub Actions cache.
2. Turns on Docker's containerd image store if it is off. This restarts Docker and needs `sudo`.
3. Gets a GitHub OIDC token with audience `cloud` and checks in: `POST {cloud}/api/builds/{build}/check-in` with `Authorization: Bearer <token>`. Cloud answers:
   ```json
   {"grant": "ployzgrant1:…", "commit": "<40 hex>", "fingerprint": "<64 hex>", "ployzVersion": "<x.y.z[-beta.n]>", "deployment": { "snapshots": [{ "resolvedEnv": {} }] }}
   ```
   The token, the grant, and every `resolvedEnv` value are masked (`::add-mask::`, per line) before anything else runs. Lines under 4 characters are not: masking `0` would star out every 0 in the log. A check-in that can't reach Cloud is retried; an HTTP error is not, and the job fails with Cloud's status and message.
4. Installs exactly `ployzVersion` from `https://ployz.sh`: the version of the Cloud process that computed `fingerprint`, so they match even while Cloud rolls out a new version. The installer verifies the release checksum. The install is timed as the first Build Step, "Installing ployz". If it fails, the Action sends Cloud a final report with that step failed and naming the version (`installFailed`), so Cloud moves the build on to the next Builder.
5. Checks out `commit` without persisting credentials.
6. Runs `PLOYZ_BUILD_GRANT=… ployz build --deployment <file> --commit <commit> --fingerprint <fingerprint> --events <file>`. The deployment file lives in `$RUNNER_TEMP` and is deleted when the job ends, pass or fail.
7. Reports the Build Steps while it builds, every few seconds, each time with a fresh OIDC token: `POST {cloud}/api/builds/{build}/steps` with `{"from": <line>, "events": [<new event lines>]}`, where `from` is the 0-based line the batch starts at. The lines are the "Installing ployz" step, then `ployz build --events`, which includes the push and its per-layer progress. Cloud files only lines it hasn't taken, so a retried batch is harmless. As soon as `ployz build` prints its result (the image is in the Machine), or when it fails, the last batch adds `"platforms": [...]`; empty means the build failed. That report settles the build, and Cloud takes no more. `ployz build` then uploads the build cache to the GitHub Actions cache; a failed upload is only a warning.

Output `digest` is the manifest digest the Machine received. Cloud does not trust it: it reads the pushed digest from the Machine when it ends the grant.

## Runner needs

Linux, Docker with Buildx, rootful Docker on the runner's network (the push goes to `127.0.0.1`), and outbound access to `relay.ployz.dev`. GitHub-hosted Ubuntu runners have all of these.

## Develop

`./test.sh` runs both scripts against stubbed `curl`, `docker`, and `ployz`. `shellcheck *.sh` must pass. `oidc.sh` holds the OIDC token helper both scripts source.

## Publish

This directory is the source of `getployz/build`. Copy it to the root of that repository, then tag the release and move the major tag:

```sh
git tag v1.0.0 && git tag -f v1 && git push origin v1.0.0 && git push -f origin v1
```
