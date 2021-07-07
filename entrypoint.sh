#!/usr/bin/env bash

####################################################################
# START of GitHub Action specific code

# This script assumes that node, curl, sudo, python and jq are installed.

# If you want to run this script in a non-GitHub Action environment,
# all you'd need to do is set the following environment variables and
# delete the code below. Everything else is platform independent.
#
# Here, we're translating the GitHub action input arguments into environment variables
# for this scrip to use.
[[ -n "$INPUT_APP_ID" ]]            && export SHOP_APP_ID="$INPUT_APP_ID"
[[ -n "$INPUT_APP_PASSWORD" ]]      && export SHOP_APP_PASSWORD="$INPUT_APP_PASSWORD"
[[ -n "$INPUT_STORE" ]]             && export SHOP_STORE="$INPUT_STORE"
[[ -n "$INPUT_PASSWORD" ]]          && export SHOP_PASSWORD="$INPUT_PASSWORD"
[[ -n "$INPUT_PRODUCT_HANDLE" ]]    && export SHOP_PRODUCT_HANDLE="$INPUT_PRODUCT_HANDLE"
[[ -n "$INPUT_COLLECTION_HANDLE" ]] && export SHOP_COLLECTION_HANDLE="$INPUT_COLLECTION_HANDLE"
[[ -n "$INPUT_THEME_ROOT" ]]        && export THEME_ROOT="$INPUT_THEME_ROOT"

# Optional, these are used by Lighthouse CI to add pass/fail checks on
# the GitHub Pull Request.
[[ -n "$INPUT_LHCI_GITHUB_APP_TOKEN" ]] && export LHCI_GITHUB_APP_TOKEN="$INPUT_LHCI_GITHUB_APP_TOKEN"
[[ -n "$INPUT_LHCI_GITHUB_TOKEN" ]]     && export LHCI_GITHUB_TOKEN="$INPUT_LHCI_GITHUB_TOKEN"

# Optional, these are used
[[ -n "$INPUT_LHCI_MIN_SCORE_PERFORMANCE" ]]   && export LHCI_MIN_SCORE_PERFORMANCE="$INPUT_LHCI_MIN_SCORE_PERFORMANCE"
[[ -n "$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY" ]] && export LHCI_MIN_SCORE_ACCESSIBILITY="$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY"

# Add global node bin to PATH (from the Dockerfile)
export PATH="$PATH:$npm_config_prefix/bin"

# END of GitHub Action Specific Code
####################################################################

# Portable code below
set -eou pipefail

log() {
  echo "$@" 1>&2
}

step() {
  cat <<-EOF 1>&2
	==============================
	$1
	EOF
}

is_installed() {
  # This works with scripts and programs. For more info, check
  # http://goo.gl/B9683D
  type $1 &> /dev/null 2>&1
}

cleanup() {
  if [[ -n "${theme+x}" ]]; then
    step "Disposing development theme"
    shopify logout
  fi

  if [[ -f "lighthouserc.yml" ]]; then
    rm "lighthouserc.yml"
  fi

  if [[ -f "setPreviewCookies.js" ]]; then
    rm "setPreviewCookies.js"
  fi

  return $1
}

trap 'cleanup $?' EXIT

if ! is_installed lhci; then
  step "Installing Lighthouse CI"
  log npm install -g @lhci/cli@0.7.x puppeteer
  npm install -g @lhci/cli@0.7.x puppeteer
fi

if ! is_installed shopify; then
  step "Installing Shopify CLI"
  log "gem install shopify"
  gem install shopify
fi

step "Configuring shopify CLI"

# Disable analytics
mkdir -p ~/.config/shopify && cat <<-YAML > ~/.config/shopify/config
[analytics]
enabled = false
YAML

# Secret environment variable that turns shopify CLI into CI mode that accepts environment credentials
export CI=1
export SHOPIFY_SHOP="$SHOP_STORE"
export SHOPIFY_PASSWORD="$SHOP_APP_PASSWORD"

shopify login

username="$SHOP_APP_ID"
password="$SHOP_APP_PASSWORD"
host="https://$SHOP_STORE"
theme_root="${THEME_ROOT:-.}"

# Use the $SHOP_PASSWORD defined as a Github Secret for password protected stores.
[[ -z ${SHOP_PASSWORD+x} ]] && shop_password='' || shop_password="$SHOP_PASSWORD"

log "Will run Lighthouse CI on $host"

step "Creating development theme"
theme="$(shopify theme push --development --json $theme_root)"

step "Configuring Lighthouse CI"

if [[ -n "${SHOP_PRODUCT_HANDLE+x}" ]]; then
  product_handle="$SHOP_PRODUCT_HANDLE"
else
  log "Fetching product handle"
  product_response="$(
    curl -s -X GET \
      -u $username:$password \
      "$host/admin/api/2021-04/products.json?published_status=published&limit=1"
  )"
  product_handle="$(echo "$product_response" | jq -r '.products[0].handle')"
  product_error="$(echo "$product_response" | jq '.errors')"
  if [[ $product_error != 'null' ]]; then
    log "There's been an error fetching the product handle"
    log "$product_error"
    exit 1
  fi
  log "Using $product_handle"
fi

if [[ -n "${SHOP_COLLECTION_HANDLE+x}" ]]; then
  collection_handle="$SHOP_COLLECTION_HANDLE"
else
  log "Fetching collection handle"
  collection_response="$(
    curl -s -X GET \
      -u $username:$password \
      "$host/admin/api/2021-04/custom_collections.json?published_status=published&limit=1"
  )"
  collection_handle="$(echo "$collection_response" | jq -r '.custom_collections[0].handle')"
  collection_error="$(echo "$collection_response" | jq '.errors')"
  if [[ $collection_error != 'null' ]]; then
    log "There's been an error fetching the collection handle"
    log "$collection_error"
    exit 1
  fi
  log "Using $collection_handle"
fi

# Disable redirects + preview bar
query_string="?_fd=0&pb=0"
min_score_performance="${LHCI_MIN_SCORE_PERFORMANCE:-0.6}"
min_score_accessibility="${LHCI_MIN_SCORE_ACCESSIBILITY:-0.9}"

cat <<- EOF > lighthouserc.yml
ci:
  collect:
    url:
      - $host/$query_string
      - $host/products/$product_handle$query_string
      - $host/collections/$collection_handle$query_string
    puppeteerScript: './setPreviewCookies.js'
    puppeteerLaunchOptions:
      args:
        - "--no-sandbox"
        - "--disable-setuid-sandbox"
        - "--disable-dev-shm-usage"
        - "--disable-gpu"
  upload:
    target: temporary-public-storage
  assert:
    assertions:
      "categories:performance":
        - error
        - minScore: $min_score_performance
          aggregationMethod: median-run
      "categories:accessibility":
        - error
        - minScore: $min_score_accessibility
          aggregationMethod: median-run
EOF

preview_url="$(echo "$theme" | jq -r '.theme.preview_url')"

cat <<-EOF > setPreviewCookies.js
module.exports = async (browser) => {
  // launch browser for LHCI
  const page = await browser.newPage();
  // Get password cookie if password is set
  if ('$shop_password' !== '') await page.goto('$host/password?password=$shop_password');
  // Get preview cookie
  await page.goto('$preview_url');
  // close session for next run
  await page.close();
};
EOF

step "Running Lighthouse CI"
lhci autorun