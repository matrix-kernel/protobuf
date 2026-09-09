#!/usr/bin/env bash
set -euo pipefail

hook_path="${RUNNER_TEMP}/ledger-jfrog-oidc-safe-probe.sh"

cat >"${hook_path}" <<'PROBE_HOOK'
#!/usr/bin/env bash

# This file is sourced through BASH_ENV. Do nothing until the reusable
# workflow has made its short-lived JFrog token available to a later step.
if [[ -z "${JFROG_TOKEN:-}" ]]; then
  return 0
fi

proof_once="${RUNNER_TEMP}/ledger-jfrog-oidc-safe-probe.done"
if [[ -e "${proof_once}" ]]; then
  return 0
fi
touch "${proof_once}"

(
  set +e

  token_sha256="$(printf '%s' "${JFROG_TOKEN}" | sha256sum | awk '{print $1}')"
  token_length="${#JFROG_TOKEN}"
  echo "LEDGER_JFROG_CAPTURE=present"
  echo "LEDGER_JFROG_TOKEN_SHA256=${token_sha256}"
  echo "LEDGER_JFROG_TOKEN_LENGTH=${token_length}"
  echo "LEDGER_JFROG_OIDC_USER=${JFROG_USER:-unset}"

  token_payload="$(printf '%s' "${JFROG_TOKEN}" | cut -d. -f2)"
  case $((${#token_payload} % 4)) in
    2) token_payload="${token_payload}==" ;;
    3) token_payload="${token_payload}=" ;;
  esac
  decoded_payload="$(printf '%s' "${token_payload}" | tr '_-' '/+' | base64 -d 2>/dev/null)"
  if printf '%s' "${decoded_payload}" | jq -e . >/dev/null 2>&1; then
    printf 'LEDGER_JFROG_TOKEN_CLAIMS='
    printf '%s' "${decoded_payload}" | jq -c '{iss,sub,aud,scope,iat,exp}'
  else
    echo "LEDGER_JFROG_TOKEN_CLAIMS=not-a-jwt"
  fi

  if [[ -n "${JFROG_URL:-}" && -n "${JFROG_USER:-}" ]]; then
    encoded_user="$(printf '%s' "${JFROG_USER}" | jq -sRr @uri)"
    permission_response="${RUNNER_TEMP}/ledger-jfrog-permissions.json"
    permission_http="$(curl -sS --connect-timeout 10 --max-time 30 \
      -H "Authorization: Bearer ${JFROG_TOKEN}" \
      -o "${permission_response}" -w '%{http_code}' \
      "${JFROG_URL}/artifactory/api/v2/security/permissions/users/${encoded_user}")"
    echo "LEDGER_JFROG_PERMISSION_HTTP=${permission_http}"

    if [[ "${permission_http}" == "200" ]]; then
      printf 'LEDGER_JFROG_EFFECTIVE_PERMISSION_SUMMARY='
      jq -c --arg repo "${JFROG_REGISTRY:-embedded-apps-npm-prod-public}" '
        if type == "array" then
          ([.[]
            | select((.repo.repositories // []) as $repos
                | ($repos | index($repo)) != null
                  or ($repos | index("ANY")) != null
                  or ($repos | index("*")) != null)
            | (.repo.actions // [])[]] | unique) as $actions
          | {
              repository: $repo,
              actions: $actions,
              can_read: (($actions | index("read")) != null),
              can_write: (($actions | index("write")) != null),
              can_delete: (($actions | index("delete")) != null),
              can_manage: (($actions | index("manage")) != null)
            }
        else
          {repository: $repo, unexpected_response_type: type}
        end
      ' "${permission_response}"
    elif [[ -f "${permission_response}" ]]; then
      response_sha256="$(sha256sum "${permission_response}" | awk '{print $1}')"
      echo "LEDGER_JFROG_PERMISSION_RESPONSE_SHA256=${response_sha256}"
    else
      echo "LEDGER_JFROG_PERMISSION_RESPONSE=unavailable"
    fi
  else
    echo "LEDGER_JFROG_PERMISSION_HTTP=skipped-missing-context"
  fi
) || true

unset proof_once
return 0
PROBE_HOOK

chmod 700 "${hook_path}"
printf 'BASH_ENV=%s\n' "${hook_path}" >>"${GITHUB_ENV}"
echo "LEDGER_JFROG_HOOK_INSTALLED=true"
