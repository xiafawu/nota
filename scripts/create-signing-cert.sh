#!/bin/bash
# Create a STABLE self-signed code-signing identity for local Nota deploys.
#
# Why: `xcodebuild` ad-hoc signs the app ("Sign to Run Locally"), which has no
# stable Designated Requirement. macOS TCC keys the Accessibility (and Input
# Monitoring) grant to that requirement, so every rebuild changes the cdhash and
# silently invalidates the grant — the Settings toggle stays ON but the app
# reads "not granted". Signing every deploy with ONE reusable self-signed cert
# gives a constant requirement, so the permission grant persists across rebuilds.
#
# Idempotent: if the identity already exists, this is a no-op.
# Run once:  bash scripts/create-signing-cert.sh
# Then deploys pick it up automatically (see deploy-macos-app.sh).

set -euo pipefail

IDENTITY_NAME="${NOTA_SIGN_ID:-Nota Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  echo "Signing identity already present: \"$IDENTITY_NAME\" — nothing to do."
  exit 0
fi

LOGIN_KEYCHAIN="$(security default-keychain -d user | tr -d ' "')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nota-cert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
P12_PASS="notalocal"

echo "Creating self-signed code-signing cert \"$IDENTITY_NAME\"..."

# X.509 with the codeSigning EKU — required for `security find-identity -p codesigning`.
# Use an explicit -config so the system openssl.cnf can't inject a second,
# CRITICAL basicConstraints (CA:TRUE) — macOS rejects the cert as "Unknown
# critical cert extension" and codesign then reports "no identity found".
# All extensions must be NON-critical for Apple's Security framework.
cat > "$WORK/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no
[dn]
CN = $IDENTITY_NAME
[v3_codesign]
basicConstraints = CA:false
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -config "$WORK/req.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -name "$IDENTITY_NAME" -passout "pass:$P12_PASS" >/dev/null 2>&1

# Import into the login keychain. -T grants codesign access to the key, -A avoids
# a per-signing prompt. You may get ONE GUI keychain prompt on first sign —
# click "Always Allow".
security import "$WORK/identity.p12" -k "$LOGIN_KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -A

# Best-effort: pre-authorize codesign to use the key non-interactively. Needs the
# login-keychain password; if it prompts and you skip it, first sign just shows a
# GUI "Always Allow" dialog instead. Harmless either way.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || \
  echo "  (note: could not pre-authorize silently — expect one 'Always Allow' prompt on first deploy)"

# A self-signed cert is NOT a valid codesigning identity until trusted for the
# codeSign policy. `find-identity -p codesigning` hides it and codesign reports
# "no identity found" without this. This prompts once for your login password.
echo "Adding codeSign trust (enter your login password if prompted)..."
security find-certificate -c "$IDENTITY_NAME" -p "$LOGIN_KEYCHAIN" > "$WORK/cert.crt"
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$WORK/cert.crt"

echo
security find-identity -v -p codesigning | grep -F "$IDENTITY_NAME" || {
  echo "ERROR: identity still not valid after trust step." >&2; exit 1; }
echo "Done. Deploys will now sign with \"$IDENTITY_NAME\"."
