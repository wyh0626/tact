#!/usr/bin/env bash
# Creates a self-signed code signing certificate, "Tact Local Signing",
# in your login keychain. scripts/build-app.sh signs with it so that every
# build has the same signature and macOS keeps the Accessibility and Screen
# Recording grants across rebuilds. It is only good for builds on this Mac;
# no Apple Developer account is involved.
set -euo pipefail

NAME="${TACT_SIGN_IDENTITY:-Tact Local Signing}"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
# The system LibreSSL writes PKCS#12 files that `security import` accepts;
# a Homebrew OpenSSL 3 earlier in PATH would need extra flags.
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "证书「${NAME}」已经存在，不用再创建。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASSWORD="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

# -T lets codesign use the key without asking every time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
echo "已创建证书「${NAME}」。现在运行 scripts/build-app.sh 就会用它签名。"
