#!/bin/bash
set -e

# Script to generate SSL certificates for testing
# Generates:
#   - test-ca-key.pem: CA private key
#   - test-ca-cert.pem: CA certificate
#   - test-s2-key.pem: Server private key
#   - test-s2-cert.pem: Server certificate (signed by CA)

SSL_DIR="${PWD}/.github/scripts/ssl"
mkdir -p "${SSL_DIR}"
cd "${SSL_DIR}"

echo "Generating SSL certificates for testing..."

# 1. Generate CA private key
echo "1. Generating CA private key..."
openssl genrsa -out test-ca-key.pem 4096

# 2. Generate self-signed CA certificate
echo "2. Generating self-signed CA certificate..."
openssl req -new -x509 -days 365000 -key test-ca-key.pem -out test-ca-cert.pem \
  -subj "/CN=test-root" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always"

# 3. Generate server private key
echo "3. Generating server private key..."
openssl genrsa -out test-s2-key.pem 4096

# 4. Generate server certificate signing request (CSR)
echo "4. Generating server CSR..."
openssl req -new -key test-s2-key.pem -out test-s2-cert.csr \
  -subj "/CN=test-memsql-server"

# 5. Sign server certificate with CA
echo "5. Signing server certificate with CA..."
openssl x509 -req -in test-s2-cert.csr -CA test-ca-cert.pem -CAkey test-ca-key.pem \
  -CAcreateserial -out test-s2-cert.pem -days 365000 -sha256

# Clean up CSR and serial file
rm -f test-s2-cert.csr test-ca-cert.srl
chmod -R 777 "${SSL_DIR}"

echo ""
echo "✓ Certificate generation complete!"
echo ""
echo "Generated files:"
echo "  - test-ca-key.pem       (CA private key)"
echo "  - test-ca-cert.pem      (CA certificate)"
echo "  - test-s2-key.pem   (Server private key)"
echo "  - test-s2-cert.pem  (Server certificate)"
echo ""
echo "Verify with:"
echo "  openssl x509 -in test-ca-cert.pem -text -noout"
echo "  openssl x509 -in test-s2-cert.pem -text -noout"
echo "  openssl verify -CAfile test-ca-cert.pem test-s2-cert.pem"
