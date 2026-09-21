#!/usr/bin/env bash
#
# Registers one ephemeral self-hosted GitHub Actions runner, runs exactly one workflow job,
# and exits.
#
# Authentication is a GitHub App, not a personal access token. Three steps:
#
#   1. Sign a short-lived RS256 JWT with the App private key.
#   2. Exchange the JWT for an installation access token, scoped to the repositories the App
#      is installed on.
#   3. Exchange the installation token for a single-use runner registration token.
#
# Only step 3's output ever reaches the runner configuration, and it is valid for one hour and
# one registration. The App key itself never leaves this process.
#
# --ephemeral is not optional. A reused runner keeps the previous job's working directory,
# environment and credentials, so one workflow could read another's secrets. Ephemeral means
# GitHub deregisters the runner after a single job and this container exits.

set -o errexit
set -o nounset
set -o pipefail

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

: "${GITHUB_APP_ID:?GITHUB_APP_ID is required}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required}"
: "${GITHUB_APP_PRIVATE_KEY:?GITHUB_APP_PRIVATE_KEY is required}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
: "${GITHUB_REPOSITORY_NAME:?GITHUB_REPOSITORY_NAME is required}"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
REPOSITORY="${GITHUB_REPOSITORY_OWNER}/${GITHUB_REPOSITORY_NAME}"

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# base64url, i.e. standard base64 with the URL-safe alphabet and no padding. JWT uses this
# everywhere; plain base64 produces a token GitHub rejects as malformed.
b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# ---------------------------------------------------------------------------------------
# 1. Sign the App JWT
# ---------------------------------------------------------------------------------------

# The key arrives from Key Vault as a single line when it was pasted that way, so literal
# "\n" sequences are turned back into real newlines. openssl accepts both the PKCS#1
# ("BEGIN RSA PRIVATE KEY") form GitHub hands out and the PKCS#8 form.
PRIVATE_KEY_FILE="${WORK_DIR}/app.pem"
printf '%b\n' "${GITHUB_APP_PRIVATE_KEY}" > "${PRIVATE_KEY_FILE}"
chmod 600 "${PRIVATE_KEY_FILE}"

NOW="$(date +%s)"
# Backdated 60 seconds to absorb clock skew between this container and GitHub, and expiring in
# 9 minutes because GitHub rejects anything more than 10 minutes out.
JWT_ISSUED_AT=$((NOW - 60))
JWT_EXPIRES_AT=$((NOW + 540))

JWT_HEADER="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
JWT_PAYLOAD="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
    "${JWT_ISSUED_AT}" "${JWT_EXPIRES_AT}" "${GITHUB_APP_ID}" | b64url)"
JWT_SIGNING_INPUT="${JWT_HEADER}.${JWT_PAYLOAD}"

JWT_SIGNATURE="$(printf '%s' "${JWT_SIGNING_INPUT}" \
    | openssl dgst -sha256 -sign "${PRIVATE_KEY_FILE}" \
    | b64url)"

APP_JWT="${JWT_SIGNING_INPUT}.${JWT_SIGNATURE}"
rm -f "${PRIVATE_KEY_FILE}"

# ---------------------------------------------------------------------------------------
# 2. Exchange it for an installation access token
# ---------------------------------------------------------------------------------------

log "Requesting an installation token for ${REPOSITORY}."

INSTALLATION_RESPONSE="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${APP_JWT}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${GITHUB_API_URL}/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")" \
    || fail "Could not mint an installation token. Check GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and the private key in Key Vault."

INSTALLATION_TOKEN="$(printf '%s' "${INSTALLATION_RESPONSE}" | jq -r '.token // empty')"
[ -n "${INSTALLATION_TOKEN}" ] || fail 'The installation token response contained no token.'

# ---------------------------------------------------------------------------------------
# 3. Exchange that for a single-use runner registration token
# ---------------------------------------------------------------------------------------

log "Requesting a runner registration token for ${REPOSITORY}."

REGISTRATION_RESPONSE="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${INSTALLATION_TOKEN}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${GITHUB_API_URL}/repos/${REPOSITORY}/actions/runners/registration-token")" \
    || fail "Could not mint a registration token. The App needs Administration: read and write on ${REPOSITORY}, and must be installed on it."

REGISTRATION_TOKEN="$(printf '%s' "${REGISTRATION_RESPONSE}" | jq -r '.token // empty')"
[ -n "${REGISTRATION_TOKEN}" ] || fail 'The registration token response contained no token.'

unset GITHUB_APP_PRIVATE_KEY APP_JWT INSTALLATION_TOKEN

# ---------------------------------------------------------------------------------------
# Configure and run
# ---------------------------------------------------------------------------------------

# The repository URL, not the API URL: `config.sh` wants the web endpoint.
REPOSITORY_URL="$(printf '%s' "${GITHUB_API_URL}" | sed 's#//api\.#//#; s#/api/v3$##')/${REPOSITORY}"

log "Registering ephemeral runner '${RUNNER_NAME}' on ${REPOSITORY} with labels ${RUNNER_LABELS}."

./config.sh \
    --url "${REPOSITORY_URL}" \
    --token "${REGISTRATION_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work '_work' \
    --unattended \
    --replace \
    --ephemeral \
    --disableupdate

# An ephemeral runner deregisters itself on a clean exit. This covers the other case: Azure
# stopping the replica at `replicaTimeout` would otherwise leave an offline runner behind,
# and those accumulate until someone prunes them by hand.
remove_runner() {
    log 'Removing the runner registration.'
    ./config.sh remove --token "${REGISTRATION_TOKEN}" || true
}
trap 'remove_runner; cleanup' EXIT
trap 'exit 143' INT TERM

log 'Waiting for a workflow job.'
./run.sh &
wait $!
