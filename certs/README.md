# Trusted CA certificates

Put PEM-encoded CA certificates (`*.pem` or `*.crt`, one or more certificates per file) into this folder and
commit them. Argo CD (app `certs`) syncs them; trust-manager combines them with the public CAs of Debian's
`ca-certificates` into the bundle

    ConfigMap company-ca-bundle, key ca-certificates.crt   (in every namespace)

Consumers mount it and read it on every use, so a change in Git reaches them within a few minutes without a
restart:

* Argo CD repo-server: `SSL_CERT_FILE` / `GIT_SSL_CAINFO` -> https Git and Helm repositories
* Alloy: `/etc/ssl/company/ca-certificates.crt` -> `tls_config { ca_file = ... }` of scrapes and exporters

Only public certificates belong here - never private keys.
