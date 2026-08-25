#!/bin/bash
# Run ONCE on your Mac to generate a stable self-signed code-signing cert.
# The resulting .p12 is used by CI to sign every build with a consistent identity,
# so macOS TCC tracks permissions by cert (not binary hash) and they survive updates.
#
# Usage:
#   chmod +x .github/gen-codesign-cert.sh
#   ./.github/gen-codesign-cert.sh
#
# Then add the two printed values to GitHub Secrets:
#   APPLE_SELF_CERT          (base64 of the .p12)
#   APPLE_SELF_CERT_PASSWORD (the password)
set -e

CERT_NAME="LightStar Code Signing"
CERT_PASS="lightstar-ci-$(date +%s | tail -c 6)"
OUT_DIR="$(mktemp -d)"

# OpenSSL config with Code Signing EKU required by codesign
cat > "$OUT_DIR/ext.cnf" <<CNF
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = LightStar Code Signing
O = adityaraj
C = US
[v3_codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "Generating 2048-bit RSA key..."
openssl genrsa -out "$OUT_DIR/key.pem" 2048 2>/dev/null

echo "Creating self-signed certificate (10 years)..."
openssl req -new -x509 \
  -key "$OUT_DIR/key.pem" \
  -out "$OUT_DIR/cert.pem" \
  -days 3650 \
  -config "$OUT_DIR/ext.cnf" \
  -extensions v3_codesign 2>/dev/null

echo "Exporting as .p12..."
# Try modern format first, fall back to legacy for older OpenSSL
openssl pkcs12 -export \
  -out "$OUT_DIR/cert.p12" \
  -inkey "$OUT_DIR/key.pem" \
  -in "$OUT_DIR/cert.pem" \
  -passout "pass:$CERT_PASS" \
  -legacy 2>/dev/null || \
openssl pkcs12 -export \
  -out "$OUT_DIR/cert.p12" \
  -inkey "$OUT_DIR/key.pem" \
  -in "$OUT_DIR/cert.pem" \
  -passout "pass:$CERT_PASS" 2>/dev/null

# Import to local keychain so you can test signing on this Mac
echo "Importing to login keychain for local use..."
security import "$OUT_DIR/cert.p12" -P "$CERT_PASS" -A 2>/dev/null || true

echo ""
echo "============================================================"
echo "  Add these TWO values to GitHub Secrets"
echo "  (Settings → Secrets and variables → Actions → New secret)"
echo "============================================================"
echo ""
echo "Secret name:  APPLE_SELF_CERT"
echo "Secret value:"
base64 -i "$OUT_DIR/cert.p12"
echo ""
echo "Secret name:  APPLE_SELF_CERT_PASSWORD"
echo "Secret value: $CERT_PASS"
echo ""
echo "============================================================"
echo "Done. Delete temp files."
rm -rf "$OUT_DIR"
