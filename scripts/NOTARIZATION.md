# Notarizing F-Chat for distribution

The build already code-signs with Developer ID + hardened runtime
(`scripts/make-app.sh`). Notarization is the remaining step so other people's
Macs run the app without a Gatekeeper warning. It is **opt-in** and needs a
one-time credential setup, because it authenticates to Apple's notary service
with your App Store Connect account.

## One-time setup (required — only you can do this)

Pick ONE of the two auth methods and store it under the keychain profile name
`FChat` (the default the build looks for).

### Option A — App Store Connect API key (recommended)
1. In App Store Connect → Users and Access → Integrations → App Store Connect API,
   create a key with the **Developer** role and download the `AuthKey_XXXX.p8`
   (you also get a **Key ID** and an **Issuer ID**).
2. Store it:
   ```sh
   xcrun notarytool store-credentials FChat \
       --key /path/to/AuthKey_XXXX.p8 \
       --key-id <KEY_ID> \
       --issuer <ISSUER_UUID>
   ```

### Option B — Apple ID + app-specific password
1. Create an app-specific password at <https://appleid.apple.com> → Sign-In and
   Security → App-Specific Passwords.
2. Store it:
   ```sh
   xcrun notarytool store-credentials FChat \
       --apple-id you@example.com \
       --team-id QS865LKS7W \
       --password <app-specific-password>
   ```

## Building a notarized app

```sh
FCHAT_NOTARIZE=1 ./scripts/make-app.sh
```

This signs the bundle, zips it, submits to the notary service (`--wait`), staples
the ticket onto `build/F-Chat.app`, and verifies with `spctl`. A normal
`./scripts/make-app.sh` skips all of this.

Override the profile name with `FCHAT_NOTARY_PROFILE=<name>` if you stored it
under a different name.

## Verifying / troubleshooting

```sh
spctl -a -vvv -t exec build/F-Chat.app          # should say: accepted, source=Notarized Developer ID
xcrun stapler validate build/F-Chat.app          # ticket present?
xcrun notarytool history --keychain-profile FChat
xcrun notarytool log <submission-id> --keychain-profile FChat   # why a submission failed
```

Common rejection cause: a nested binary not signed with hardened runtime — the
build signs the vendored Python tree inside-out to avoid this.
