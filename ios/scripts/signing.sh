# Sourced by install-on-iphone.sh and testflight.sh: make sure
# Signing.local.xcconfig names your team and bundle id.
#   $1 (optional) bundle id to use on first setup, e.g. com.yourname.tiro
ensure_signing() {
  if grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Signing.local.xcconfig; then
    return 0
  fi
  TEAM="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)"
  if [ -z "$TEAM" ]; then
    echo "No Apple Development certificate yet. In Xcode: Settings → Accounts → add your Apple ID," >&2
    echo "select it → Manage Certificates → + → Apple Development. Then run this again." >&2
    exit 1
  fi
  if [ -z "${1:-}" ]; then
    echo "First run: pass a bundle id only you use, e.g.  $0 com.yourname.tiro" >&2
    exit 1
  fi
  printf 'DEVELOPMENT_TEAM = %s\nTIRO_BUNDLE_ID = %s\n' "$TEAM" "$1" > Signing.local.xcconfig
  echo "Wrote Signing.local.xcconfig (team $TEAM, bundle $1)"
}
