# Apple iOS Signing Credentials Setup Guide

This document describes how to obtain and configure the Apple signing credentials required for AutoBrain iOS releases.

## Required Credentials

1. **Apple Distribution Certificate** (`.p12` file)
2. **Provisioning Profile** (`.mobileprovision` file) — optional if using `-allowProvisioningUpdates`
3. **App Store Connect API Key** (`.p8` file with Key ID and Issuer ID)
4. **Team ID** (10-character Apple Developer Team identifier)

## Step 1: Create Apple Distribution Certificate

1. Log in to [Apple Developer Portal](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Profiles** → **Certificates**
3. Click **+** to create a new certificate
4. Select **Apple Distribution** (not "iOS Distribution" — that's legacy)
5. Generate a Certificate Signing Request (CSR) from your Mac:
   ```bash
   # On macOS, open Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority
   # Save as certSigningRequest.csr
   ```
6. Upload the CSR and download the certificate (`.cer` file)
7. Double-click the `.cer` to install in Keychain Access
8. In Keychain Access, find the certificate (named "Apple Distribution: AutoBrain"), right-click → **Export**
9. Save as `Apple_Distribution_AutoBrain.p12` with a strong password

## Step 2: Create App Store Connect API Key

1. Log in to [App Store Connect](https://appstoreconnect.apple.com)
2. Navigate to **Users and Access** → **Keys** → **App Store Connect API Keys**
3. Click **+** to generate a new key
4. Name: `AutoBrain-CI-Release`
5. Role: **App Manager** (minimum for TestFlight/App Store uploads)
6. Download the `.p8` file **immediately** (cannot be downloaded again)
7. Note the **Key ID** (e.g., `ABC123DEFG`) and **Issuer ID** (UUID, e.g., `12345678-1234-1234-1234-123456789012`)

## Step 3: Get Team ID

1. In Apple Developer Portal → **Membership** → **Team ID**
2. Or in App Store Connect → **Users and Access** → **Keys** → any key → **Issuer ID** (same as Team ID)

## Step 4: Create Provisioning Profile (Optional)

**Note**: The CI pipeline uses `xcodebuild -allowProvisioningUpdates` which can create/update the distribution profile automatically using the App Store Connect API key. A manual profile is only needed if you want to pin a specific profile.

If creating manually:
1. Apple Developer Portal → **Profiles** → **+**
2. Type: **App Store** (Distribution)
3. App ID: `com.autobrain.autobrain`
4. Select the **Apple Distribution** certificate created in Step 1
5. Name: `AutoBrain App Store Distribution`
6. Download as `AutoBrain_App_Store_Distribution.mobileprovision`

## Step 5: Configure GitHub Secrets

Use the `setup-ios-signing.sh` script:

```bash
./setup-ios-signing.sh \
    Apple_Distribution_AutoBrain.p12 \
    "your-cert-password" \
    AutoBrain_App_Store_Distribution.mobileprovision \
    AuthKey_ABC123DEFG.p8 \
    ABC123DEFG \
    12345678-1234-1234-1234-123456789012 \
    TEAM123456
```

Or if skipping provisioning profile:
```bash
./setup-ios-signing.sh \
    Apple_Distribution_AutoBrain.p12 \
    "your-cert-password" \
    - \
    AuthKey_ABC123DEFG.p8 \
    ABC123DEFG \
    12345678-1234-1234-1234-123456789012 \
    TEAM123456
```

### Secrets Set by Script

| Secret | Description |
|--------|-------------|
| `IOS_CERT_P12_BASE64` | Base64-encoded .p12 certificate |
| `IOS_CERT_PASSWORD` | Certificate password |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64-encoded .mobileprovision (empty if using -allowProvisioningUpdates) |
| `IOS_TEAM_ID` | 10-character Team ID |
| `APPLE_STORE_API_KEY` | JSON with key_id, issuer_id, private_key |
| `APPLE_STORE_KEY_ID` | Key ID (for compatibility) |
| `APPLE_STORE_ISSUER_ID` | Issuer ID (for compatibility) |

## Step 6: Verify Setup

1. Go to GitHub Actions in `autobrain-mobile` repo
2. Run **"Diagnose iOS signing chain on macOS runner"** workflow
3. Check that the certificate appears as valid (not `CSSMERR_TP_NOT_TRUSTED`)
4. Run **"Release (.ipa)"** workflow with `lane: beta` to test TestFlight upload

## Troubleshooting

### Certificate shows as "CSSMERR_TP_NOT_TRUSTED"
The macOS runner is missing Apple WWDR intermediate certificates. Run on the runner:
```bash
# Download and install Apple WWDR intermediates
curl -o AppleWWDRCA.cer https://www.apple.com/certificateauthority/AppleWWDRCA.cer
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain AppleWWDRCA.cer
```

### "No profiles for bundle ID found"
Ensure the App Store Connect API key has **App Manager** role and the bundle ID `com.autobrain.autobrain` is registered in Apple Developer Portal.

### altool "Failed to load AuthKey file"
The `.p8` file must be staged in `~/.appstoreconnect/private_keys/` — the release workflow handles this automatically.

## Security Notes

- **Never commit** `.p12`, `.mobileprovision`, or `.p8` files to any repository
- Store credentials in 1Password or similar password manager
- Rotate certificates annually (they expire)
- Rotate App Store Connect API keys if compromised
- Limit GitHub secret access to required workflows only

## References

- AUT-3226: Original task for iOS signing setup
- AUT-4355: Migration to -allowProvisioningUpdates
- AUT-5113: Bundle ID alignment (com.autobrain.autobrain)
- release-ios.yml: CI workflow that uses these secrets
