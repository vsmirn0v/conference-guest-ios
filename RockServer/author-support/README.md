# Author support claims

The standalone loopback registry stores only an anonymous device public-key hash, a random nonce, claim status, and the signed receipt. It has no provider credentials or signing key. Requests are limited globally and per in-memory client IP; IP addresses are not logged or persisted. Unclaimed registrations expire after 30 minutes. The database has a 50,000-record and 32 MiB limit; signed receipts are retained for refresh. Monitor capacity and do not delete issued grants without an explicit retention decision.

After independently authenticating the Boosty membership, run locally:

```sh
python3 RockServer/author-support/operator.py issue --through UNIX_SECONDS
```

Enter the displayed claim code at the hidden prompt. Store that code privately as the enrollment reference: it is the administrator's lookup handle for later renewal and revocation. `renew --through UNIX_SECONDS` and `revoke` use the same prompt and update the original device and nonce with a strictly higher revision. Revocation uses `through=0`. This does not automatically verify payment, renew memberships, or retain donor identity. The operator signs locally using the dedicated Keychain account and checks its expected public key, verifies the signature and compares the public HTTPS readback. Do not copy the Keychain secret to the host.

On the server, `rock-author-support.service` listens only on 127.0.0.1:18792. SQLite data is under `/var/lib/rock-author-support`, mode 0700; host root SSH is the operator boundary. Nginx serves the separately signed catalog from `/var/www/rocknroll/author-support/catalog.json` and proxies `/author-support/` to the service. Nginx access logging is disabled for this site. Preserve database and signing key backups independently. Roll back an nginx change by restoring the retained site backup, running `nginx -t`, and reloading nginx; stop only this service if necessary. Never roll back or delete the database merely to roll back routing.
