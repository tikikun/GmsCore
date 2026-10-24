# Local fix: fail-open authorization in `PackageUtils.callerHasGooglePackagePermission`

**Status:** reported privately to ReVanced as `GHSA-vmh6-hg8f-p97c` (state: triage, as of
2026-10-24). This note is published in the fork by the fork owner, ahead of upstream triage.

**Upstream issue:** https://github.com/ReVanced/GmsCore/issues/10 (closed 2024-03-27 as "completed")
**Fork status:** inherited unfixed. Line untouched since `2e279c48`; still present at `main`
(`776a8fb7` / `v0.3.13.3.250932`). Upstream `microg/GmsCore` is **not** affected — it has
neither the spoofing feature nor the fail-open.

## The bug

`play-services-base/core/src/main/java/org/microg/gms/common/PackageUtils.java:85-88`

```java
// See https://github.com/ReVanced/GmsCore/issues/10.
ExtendedPackageInfo extendedPackageInfo = new ExtendedPackageInfo(context, packageName);
if (!extendedPackageInfo.isInstalled())
    return true;                       // fail open -> grants EVERY GooglePackagePermission
```

`packageName` here is the **spoofed** name, taken from the calling app's own unprotected
manifest meta-data (`PackageSpoofUtils.kt:100-113`, key
`app.revanced.android.gms.SPOOFED_PACKAGE_NAME`). Any app can declare it.

An app that declares `SPOOFED_PACKAGE_NAME` = any *not installed* package passes
`callerHasGooglePackagePermission()` for every permission value — ACCOUNT, AUTH, OWNER,
PEOPLE, IMPERSONATE, APP_CERT, CREDENTIALS, SAFETYNET, WALLET, AD_ID, REPORTING.

## Fix

Suggested one-hunk change (applies cleanly; not yet applied in this tree):

```diff
-if (!extendedPackageInfo.isInstalled())
-    return true;
+if (!extendedPackageInfo.isInstalled()) {
+    Log.w("ExtendedAccess", "Denying spoofed package " + packageName + ": not installed");
+    continue;
+}
```

`continue` (not `return false`) so the loop still evaluates the caller's *real* package as the
next candidate — the fix denies the unverifiable identity without denying the real one.

## Functional impact — read before applying

24 call sites across 12 files: AdvertisingId, location reporting, location sharing, games
first-party, app cert, auth proxy, credential manager, people, account content provider,
auth manager, safetynet.

**The break only occurs when the spoof target is not installed.** If the original app is still
installed side-by-side with the patched one (ReVanced's recommended setup), `isInstalled()`
is true, the new branch is never taken, and behaviour is unchanged. If you *replaced* the
original, patched apps will lose Google APIs.

If you replaced originals and need to keep working, the bounded variant is: honour the spoof
claim only when the declaring APK's signing certificate matches your own release key
(hardcode your cert digest for a personal build), else deny.

## Building and installing via adb

At `main` HEAD the flavor→package mapping was swapped by upstream `776a8fb7`:

| Variant | applicationId |
|---|---|
| `MapboxUserRelease` | **`app.revanced.android.gms`** ← this is the one, to replace the ReVanced build |
| `MapboxDefaultRelease` | `com.google.android.gms` |
| `MapboxHuaweiRelease` | `app.revanced.android.gms` (`-hw`) |

```bash
./gradlew --no-daemon :play-services-core:assembleMapboxUserRelease
# output: play-services-core/build/outputs/apk/... (UNSIGNED)
apksigner sign --ks <your.keystore> --out signed.apk <built>.apk
adb install -r signed.apk
```

**Expect `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.** Your signature will differ from the official
ReVanced build's, so you must uninstall first:

```bash
adb uninstall app.revanced.android.gms
adb install signed.apk
```

Uninstalling **discards the Google session stored in GmsCore** — you will have to sign in
again. Sign with the *same* key on every subsequent build so `adb install -r` works cleanly
after that.

`versionName` comes from `git describe --tags`; a `-dirty` suffix means the tree is modified
(which it will be, with this patch) — cosmetic only.
