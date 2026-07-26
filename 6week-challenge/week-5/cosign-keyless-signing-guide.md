# Keyless Evidence Signing with Cosign — Setup & Verification Guide

A short, reproducible guide to signing evidence **keylessly** with
[Sigstore](https://www.sigstore.dev/) `cosign`, and — the part everyone trips
on — verifying it by pinning the exact signer identity. Written against
**cosign v3.1.2**.

## Why keyless

Keyless signing means **no private key to generate, store, rotate, or leak.**
When you sign, cosign gets a short-lived certificate from Sigstore's CA
(Fulcio) that binds the signature to *your verified identity* (the email from
an OIDC login), and records the event in a public transparency log (Rekor).
Anyone can later prove the artifact is authentic and untouched **without
trusting you** — they check the signature, the identity, and the log entry.

For GRC evidence this is ideal: the thing proving your audit evidence is
authentic has no secret of its own to protect.

> **Public log warning:** Rekor is public. The artifact's digest and your
> signing identity (email) are logged forever. Sign evidence, never secrets.

## Prerequisites

- `cosign` — `brew install cosign` (macOS) or see the
  [releases](https://github.com/sigstore/cosign/releases). Confirm with
  `cosign version`.
- The artifact you want to sign (here: an evidence bundle, e.g.
  `week5-evidence.tar.gz`).
- A browser and an identity you can log in with — **GitHub, Google, or
  Microsoft**.

## 1. Sign the artifact (keyless)

```bash
cosign sign-blob --yes --bundle <artifact>.sig.bundle <artifact>
# also record an integrity sidecar:
shasum -a 256 <artifact> > <artifact>.sha256
```

A browser opens to the Sigstore OAuth page. Pick a provider, authenticate, and
cosign writes `<artifact>.sig.bundle` — a single file packing the signature,
the certificate, and the transparency-log proof.

## 2. Discover the exact identity + issuer (do not guess)

Verification pins the certificate's **OIDC issuer** and **identity (subject)**.
The authoritative way to learn them is to let cosign print what is actually in
the cert: run a verify with deliberately wrong values and read the rejection.

```bash
cosign verify-blob --bundle <artifact>.sig.bundle \
  --certificate-identity     'discover-me' \
  --certificate-oidc-issuer  'discover-me' \
  <artifact>
```

cosign rejects it and prints the real values, e.g.:

```
...none of the expected identities matched what was in the certificate,
got subject(s) [you@example.com] with issuer https://github.com/login/oauth
```

Copy the **subject** (your identity) and the **issuer** verbatim.

Likely issuer values by provider — *confirm with the step above, don't assume*:

| Provider  | Typical issuer                          |
|-----------|-----------------------------------------|
| GitHub    | `https://github.com/login/oauth`        |
| Google    | `https://accounts.google.com`           |
| Microsoft | `https://login.microsoftonline.com`     |

Some interactive flows instead record `https://oauth2.sigstore.dev/auth` — one
more reason to read the value rather than guess it.

**Fallback** (inspect the certificate directly, for the v3 bundle format):

```bash
jq -r '.verificationMaterial.certificate.rawBytes
      // .verificationMaterial.x509CertificateChain.certificates[0].rawBytes' \
  <artifact>.sig.bundle | base64 -d \
  | openssl x509 -inform DER -noout -text \
  | grep -A1 'Subject Alternative Name'   # -> your identity (email)
```

## 3. Verify, pinning identity + issuer

```bash
cosign verify-blob --bundle <artifact>.sig.bundle \
  --certificate-identity     '<subject from step 2>' \
  --certificate-oidc-issuer  '<issuer from step 2>' \
  <artifact>
# -> Verified OK
```

Prefer the **regex** variants when scripting (anchor with `^...$` and escape
dots):

```bash
cosign verify-blob --bundle <artifact>.sig.bundle \
  --certificate-identity-regexp    '^you@example\.com$' \
  --certificate-oidc-issuer-regexp '^https://github\.com/login/oauth$' \
  <artifact>
```

## 4. Integrity + the tamper test

Authenticity proves *who* signed; integrity proves the bytes did not change.

```bash
# integrity: recompute and compare the sidecar
shasum -a 256 -c <artifact>.sha256      # -> <artifact>: OK

# tamper test: one changed byte must break it
cp <artifact> /tmp/tampered && echo junk >> /tmp/tampered
shasum -a 256 -c <artifact>.sha256 </dev/null 2>&1   # (against a tampered copy: FAILS)
```

## Using this in the GRC evidence pipeline

This challenge wraps the two commands above in scripts so evidence joins one
chain of custody:

- `sign-evidence.sh` — bundles the evidence, writes the `.sha256`, and runs
  step 1.
- `verify-evidence.sh` — runs integrity (step 4) **and** authenticity (step 3),
  and prints `CHAIN INTACT` only if both pass. Pin the signer via two env vars
  (regex):

```bash
EXPECT_ISSUER='https://github.com/login/oauth' \
EXPECT_IDENTITY='^you@example\.com$' \
./verify-evidence.sh evidence/week5-evidence.tar.gz
# -> CHAIN INTACT
```

`verify-evidence.sh` **defaults** to the CI signer identity (the GitHub Actions
workflow). For a **locally** signed bundle, override both env vars with the
values you discovered in step 2 — that is the whole reason step 2 exists.

## Gotchas

- **Same cosign version to sign and verify.** cosign v3 writes the new Sigstore
  bundle format by default; verifying with the same v3 binary round-trips
  cleanly.
- **CI-signed ≠ locally-signed.** They have different identities and issuers.
  Pin whichever actually signed the bundle in front of you.
- **`--certificate-identity-regexp` is a Go RE2 regex.** Unescaped dots match
  any character — harmless here, but anchor and escape for a real pin.
- **No network at verify time?** Verification needs Sigstore's trust root
  (fetched/cached via TUF). First run online; it caches afterward.
