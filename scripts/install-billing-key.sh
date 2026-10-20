#!/bin/zsh
# Gives each billing-feed device (the Mac notch and the LumaCore Revenue Apple TV) its own random key,
# saves the keys owner-only under ~/.config/lumacore, and sets the dashboard's BILLING_FEED_TOKENS in
# Vercel production to exactly those keys. Nothing secret is printed.
#
#   install-billing-key.sh            create any missing keys, then sync Vercel
#   install-billing-key.sh --rotate tv  replace one device's key (revoking the old one), then sync Vercel
#
# Redeploy production afterwards so the new value takes effect.
set -euo pipefail
umask 077
dashboard="${DASHBOARD_DIR:-$HOME/Projects/LumaCore/Code/Active/lumacore-dashboard}"
dir="$HOME/.config/lumacore"
mkdir -p "$dir"
typeset -A files=(notch "$dir/notch-billing-key" tv "$dir/tv-billing-key")

if [[ "${1:-}" == "--rotate" ]]; then
  [[ -n "${files[${2:-}]:-}" ]] || { echo "Usage: $0 --rotate notch|tv" >&2; exit 2; }
  rm -f "${files[$2]}"
fi
for device in notch tv; do
  file="${files[$device]}"
  if [[ ! -s "$file" ]]; then
    openssl rand -hex 32 > "$file"
    echo "Created a new $device key."
  fi
  chmod 600 "$file"
done

value="$(tr -d '\n' < "${files[notch]}"),$(tr -d '\n' < "${files[tv]}")"
cd "$dashboard"
vercel env rm BILLING_FEED_TOKENS production --yes >/dev/null 2>&1 || true
printf '%s' "$value" | vercel env add BILLING_FEED_TOKENS production --sensitive >/dev/null
echo "Set BILLING_FEED_TOKENS in Vercel production (notch and tv keys). Redeploy production to apply it."
