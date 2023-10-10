# Setting up mTLS with Nginx

## Steps Overview
  1. Create a CA, and key/cert pair on the server
  1. Config nginx to accept/validate mTLS for domain
  1. Create and sign a client key/cert.
  1. (Optional) Set up a CRL (Cert Revocation List) if you want to support
     multiple users
  1. Enjoy

### Server CA setup
  1. create a sever CA (certificate authority)
  1. create a server secret key (used to sign any client CSR)
  1. create a server cert to validate clients

```sh
# The following commands will work anywhere, but this doc assumes you're using
# the standard nginx config directory
cd /etc/nginx
mkdir mTLS-certs/
cd mTLS-certs/

# Create the server sided CA and keys with a default validity of 3 years
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -keyout server-mtls-key.pem -out server-mtls-cert.pem -days 1095

# You'll be prompted for information needed to build the cert. The only one
# that's important is CN (common name) the rest can be blank, or filled with
# fake data

If you enter '.', the field will be left blank.
-----
Country Name (2 letter code) [AU]: US
State or Province Name (full name) [Some-State]: Any State
Locality Name (eg, city) []:
Organization Name (eg, company) [Internet Widgits Pty Ltd]: example.com
Organizational Unit Name (eg, section) []:
Common Name (e.g. server FQDN or YOUR name) []: mtls.example.com
Email Address []: you-email@example.com
```

### Nginx Config
  1. Add client CA file to site config file
  1. Add `ssl_verify_client` either no to reject failed connections
    or optional if you want write custom logic.

```nginx
server{
    listen 443 ssl;
    server_name mtls.example.com;

    # Standard keys/cert configuration here

    ssl_client_certificate mTLS-certs/server-mtls-cert.pem;
    ssl_verify_client on;
    # other options include
    # 
    # ssl_verify_client optional;
    # clients can provide a valid, and signed key, or no key at all
    # 
    # ssl_verify_client optional_no_ca;
    # clients are able to provide any key, or no key at all
    # if the key is valid and signed 
    # $ssl_client_verify will be equal to "SUCCESS"
    # if the client provides a key that is unsigned
    # $ssl_client_verify will be equal to "FAILED:self-signed certificate"
    # if the client fails to provide any key 
    # $ssl_client_verify will be equal to "NONE"

}
```

Or allowing clients to connect without mTLS, but enforcing it where needed
with with custom logic.

```nginx
server{
    listen 443 ssl;
    server_name mtls.example.com;

    # Standard keys/cert configuration here

    ssl_client_certificate mTLS-certs/server-ca.pem;
    ssl_verify_client optional;

    location /secret {
        if ( $ssl_client_verify != SUCCESS) {
            return 403 'mTLS required\n\n';
        }
    }
}
```

Restart nginx

### Client Cert Setup
  Most of these steps can be done on the client, or the server.
  1. Create a client key
  1. Create a CSR (cert signing request)
  1. Sign the CSR with the server's CA. (on the server)
  1. (Optional) Create a pkcs12 file for webbrowsers

```sh
# This section can be done on the client, or the server.

# generate a client secret key (you should change client-name to something meaningful)
openssl genpkey -algorithm ec -pkeyopt ec_paramgen_curve:secp384r1 -out client-name-key.pem

# generate a certificate signing request
openssl req -new -key client-name-key.pem -subj '/CN=client-name' -out client-name.csr

# If you didn't generate these both on the server, you'll need to upload
# client-name.csr to the server, so the CA can sign it.
openssl x509 -req -in client-name.csr -CA srv-mtls-cert.pem -CAkey srv-mtls-key.pem -CAcreateserial -days 365 -out client-name.crt

# Keey a copy of client-name.csr, and client-name.crt on the server (to create a
# CRL later if required)
# And copy client-name.crt back to the client if the client key only lives on
# the client.

# In order to easily use the client key/cert in a browser, you'll need a pkcs,
# you can create one once you have both the client key and the signed cert.

openssl pkcs12 -export -out client-name.p12 -inkey client-name-key.pem -in client-name.crt
```
You're done, you can test the client and key using curl with

`curl -vvv https://mtls.example.com/ --key client-name-key.pem --cert client-name.crt`

Or by installing the created `client-name.p12` into your browser's user
certificates.

### Optional CRL setup
  1. TODO write this section
