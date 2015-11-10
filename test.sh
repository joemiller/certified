set -e -x

export PATH="$(cd "$(dirname "$0")" && pwd)/bin:$PATH"
. "$(dirname "$(dirname "$0")")/lib/certified.sh"

TMP="$(mktemp -d "$PWD/certified-XXXXXX")"
cd "$TMP"
trap "rm -rf \"$TMP\"" EXIT INT QUIT TERM

# Convert the decimal serial number from x509(1) to hex for crl(1).
serial() {
    printf "0%X" "$(
        openssl x509 -in "$1" -noout -text |
        awk '/Serial Number:/ {print $3}'
    )"
}

# Test that we can encrypt the intermediate CA and other private keys.
certified-ca --db="etc/encrypted-ssl" --encrypt-intermediate --intermediate-password="intermediate-password" --root-password="root-password" C="US" ST="CA" L="San Francisco" O="Certified" OU="OrgUnit" CN="Certified CA"
grep -q "ENCRYPTED" "etc/encrypted-ssl/private/ca.key"
certified --ca-password="intermediate-password" --db="etc/encrypted-ssl" --encrypt --password="password" CN="Certificate"
grep -q "ENCRYPTED" "etc/encrypted-ssl/private/certificate.key"

# Test that you don't need a CA to generate a CSR.
certified-csr C="US" ST="CA" L="San Francisco" O="Certified" OU="OrgUnit" CN="No CA"
openssl req -in "etc/ssl/no-ca.csr" -noout -text |
grep -q "Subject: C=US, ST=CA, L=San Francisco, O=Certified, OU=OrgUnit, CN=No CA"
test ! -f "etc/ssl/certs/no-ca.crt"

# Test that you don't need a CA to self-sign a certificate.
certified-crt --self-signed CN="No CA"
openssl x509 -in "etc/ssl/certs/no-ca.crt" -noout -text |
grep -q "Issuer: CN=No CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"
openssl x509 -in "etc/ssl/certs/no-ca.crt" -noout -text |
grep -q "Subject: CN=No CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"

# Test that we can generate a CA even after self-signing a certificate.
certified-ca --crl-url="http://example.com/ca.crl" --ocsp-url="http://ocsp.example.com" --root-crl-url="http://example.com/root-ca.crl" --root-password="root-password" C="US" ST="CA" L="San Francisco" O="Certified" OU="OrgUnit" CN="Certified CA"
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -q "Issuer: C=US, ST=CA, L=San Francisco, O=Certified, OU=OrgUnit, CN=Certified CA"
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -q "Subject: CN=Certified CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"
if ! date -d"now" 2>"/dev/null"
then
    openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
    grep -E -q "Not After : $(date -d"+3650 days" +"%b %e %H:%M:[0-6][0-9] %Y")"
fi
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -E -q '(RSA )?Public[ -]Key: \(4096 bit\)'
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -A"3" "X509v3 CRL Distribution Points" |
grep -q "http://example.com/ca.crl"
openssl x509 -in "etc/ssl/certs/root-ca.crt" -noout -text |
grep -A"3" "X509v3 CRL Distribution Points" |
grep -q "http://example.com/root-ca.crl"
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -q "OCSP - URI:http://ocsp.example.com"

# Test that we can't generate another CA.
certified-ca C="US" ST="CA" L="San Francisco" O="Certified" CN="New CA" &&
false
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -q "Subject: CN=Certified CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"

# Test that we can still self-sign a certificate.
certified --self-signed CN="Self-Signed Certificate"
openssl x509 -in "etc/ssl/certs/self-signed-certificate.crt" -noout -text |
grep -q "Issuer: CN=Self-Signed Certificate"
openssl x509 -in "etc/ssl/certs/self-signed-certificate.crt" -noout -text |
grep -q "Subject: CN=Self-Signed Certificate"

# Add a bunch of certificates to ensure we can overflow the serial number.
# This is disabled by default because it takes forever.
#seq 256 | while read SEQ
#do certified CN="Certificate $SEQ"
#done

# Test that we can sign a certificate with our CA and that it has the correct
# version and bit width.
certified CN="Certificate"
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -q "Version: 3"
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -q "Issuer: CN=Certified CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -q "Subject: CN=Certificate, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"
if ! date -d"now" 2>"/dev/null"
then
    openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
    grep -E -q "Not After : $(date -d"+365 days" +"%b %e %H:%M:[0-6][0-9] %Y")"
fi
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -E -q '(RSA )?Public[ -]Key: \(2048 bit\)'
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -A"3" "X509v3 CRL Distribution Points" |
grep -q "http://example.com/ca.crl"
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -q "OCSP - URI:http://ocsp.example.com"
openssl verify "etc/ssl/certs/certificate.crt" |
grep -q "error 20"
cat "etc/ssl/certs/ca.crt" "etc/ssl/certs/root-ca.crt" >"etc/ssl/certs/ca.chain.crt"
openssl verify -CAfile "etc/ssl/certs/ca.chain.crt" "etc/ssl/certs/certificate.crt" |
grep -q "OK"

# Test that we can't reissue a certificate without revoking it first.
certified CN="Certificate" && false

# Test that we can revoke and reissue a certificate.
SERIAL="$(serial "etc/ssl/certs/certificate.crt")"
certified --revoke CN="Certificate"
openssl crl -in "etc/ssl/crl/ca.crl" -noout -text |
grep -q "Serial Number: $SERIAL"
certified CN="Certificate"
openssl x509 -in "etc/ssl/certs/certificate.crt" -noout -text |
grep -q "Subject: CN=Certificate, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"

# Test that we can generate certificates with encrypted private keys.
certified --encrypt --password="password" CN="Encrypted"
grep -q "ENCRYPTED" "etc/ssl/private/encrypted.key"

# Test that we can generate 4096-bit certificates.
certified --bits="4096" CN="4096"
openssl x509 -in "etc/ssl/certs/4096.crt" -noout -text |
grep -E -q '(RSA )?Public[ -]Key: \(4096 bit\)'

# Test that we can generate certificates only valid until tomorrow.
certified --days="1" CN="Tomorrow"
if ! date -d"now" 2>"/dev/null"
then
    openssl x509 -in "etc/ssl/certs/tomorrow.crt" -noout -text |
    grep -E -q "Not After : $(date -d"tomorrow" +"%b %e %H:%M:[0-6][0-9] %Y")"
fi

# Test that we can change the name of the certificate file.
certified --name="filename" CN="certname"
openssl x509 -in "etc/ssl/certs/filename.crt" -noout -text |
grep -q "Subject: CN=certname"

# Test that we can add subject alternative names to a certificate.
certified CN="SAN" +"127.0.0.1" +"example.com"
openssl x509 -in "etc/ssl/certs/san.crt" -noout -text |
grep -q "DNS:example.com"
openssl x509 -in "etc/ssl/certs/san.crt" -noout -text |
grep -q "IP Address:127.0.0.1"

# Test that a valid DNS name as CN is added as a subject alternative name.
certified CN="example.com"
openssl x509 -in "etc/ssl/certs/example.com.crt" -noout -text |
grep -q "DNS:example.com"

# Test that we can add DNS wildcards to a certificate.
certified CN="Wildcard" +"*.example.com"
openssl x509 -in "etc/ssl/certs/wildcard.crt" -noout -text |
grep -F -q "DNS:*.example.com"

# Test that we can't add double DNS wildcards to a certificate.
certified CN="Double Wildcard" +"*.*.example.com" && false

# Test that we can delegate signing to an alternative CA.
certified --ca CN="Sub CA"
openssl x509 -in "etc/ssl/certs/sub-ca.crt" -noout -text |
grep -q "Issuer: CN=Certified CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"
openssl x509 -in "etc/ssl/certs/sub-ca.crt" -noout -text |
grep -q "Subject: CN=Sub CA"
cat "etc/ssl/certs/ca.crt" "etc/ssl/certs/root-ca.crt" >"etc/ssl/certs/ca.chain.crt"
openssl verify -CAfile "etc/ssl/certs/ca.chain.crt" "etc/ssl/certs/sub-ca.crt" |
grep -q "OK"
certified --issuer="Sub CA" CN="Sub Certificate"
openssl x509 -in "etc/ssl/certs/sub-certificate.crt" -noout -text |
grep -q "Issuer: CN=Sub CA, C=US, L=San Francisco, OU=OrgUnit, O=Certified, ST=CA"
openssl x509 -in "etc/ssl/certs/sub-certificate.crt" -noout -text |
grep -q "Subject: CN=Sub Certificate"
openssl verify -CAfile "etc/ssl/certs/ca.crt" "etc/ssl/certs/sub-certificate.crt" |
grep -q "error 20"
cat "etc/ssl/certs/sub-ca.crt" "etc/ssl/certs/ca.crt" "etc/ssl/certs/root-ca.crt" >"etc/ssl/certs/sub-ca.chain.crt"
openssl verify -CAfile "etc/ssl/certs/sub-ca.chain.crt" "etc/ssl/certs/sub-certificate.crt" |
grep -q "OK"

# Test that we can revoke a certificate signed by an alternative CA.
SERIAL="$(serial "etc/ssl/certs/sub-certificate.crt")"
certified --issuer="Sub CA" --revoke CN="Sub Certificate"
openssl crl -in "etc/ssl/crl/sub-ca.crl" -noout -text |
grep -q "Serial Number: $SERIAL"

# Test that we can revoke the intermediate CA and can't sign any certificates
# until it's regenerated.
SERIAL="$(serial "etc/ssl/certs/ca.crt")"
certified-ca --root-password="root-password" --revoke
openssl crl -in "etc/ssl/crl/root-ca.crl" -noout -text |
grep -q "Serial Number: $SERIAL"
certified CN="Intermediate Revoked" && false
certified-ca --root-password="root-password" CN="Certified CA"
openssl x509 -in "etc/ssl/certs/ca.crt" -noout -text |
grep -A"3" "X509v3 CRL Distribution Points" |
grep -q "http://example.com/ca.crl"
certified CN="Intermediate Regenerated"
openssl x509 -in "etc/ssl/certs/intermediate-regenerated.crt" -noout -text |
grep -A"3" "X509v3 CRL Distribution Points" |
grep -q "http://example.com/ca.crl"
openssl verify "etc/ssl/certs/intermediate-regenerated.crt" |
grep -q "error 20"
cat "etc/ssl/certs/ca.crt" "etc/ssl/certs/root-ca.crt" >"etc/ssl/certs/ca.chain.crt"
openssl verify -CAfile "etc/ssl/certs/ca.chain.crt" "etc/ssl/certs/intermediate-regenerated.crt" |
grep -q "OK"

set +x
echo >&2
if ! date -d"now" 2>"/dev/null"
then log "did not check dates on certificates because date(1) is not GNU date(1)"
fi
echo "$(tput "bold")PASS$(tput "sgr0")" >&2
