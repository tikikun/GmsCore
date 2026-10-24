# Local fix: fail-open authorization in `PackageUtils.callerHasGooglePackagePermission`

**Status:** reported privately to ReVanced as `GHSA-vmh6-hg8f-p97c` (state: triage, as of
2026-10-24). This note is published in the fork by the fork owner, ahead of upstream triage.

**Upstream issue:** https://github.com/ReVanced/GmsCore/issues/10 (closed 2024-03-27 as "completed")
**Fork status:** **fixed locally** in `347ef58f` on top of `776a8fb7` (`v0.3.13.3.250932`). Upstream `microg/GmsCore` is **not** affected — it has
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

---

## Applied fix (local)

Commit `347ef58f` — `PackageUtils.callerHasGooglePackagePermission()` now denies an
uninstalled spoof target and `continue`s to the next caller candidate.

### A/B proof that it changes exactly one behaviour

Two builds of the same tree, differing only by that hunk, then baksmali + `diff -rq`:

```
A/B diff (fixed vs no-fix), 32,728 smali files each:
  com/google/android/gms/BuildConfig.smali        <- versionName only ('-dirty' vs '-3 (347ef58)')
  org/microg/gms/common/PackageUtils.smali        <- the fix
```

Semantic diff of `PackageUtils.smali`, ignoring line/label churn:

```diff
-    return v4                                     # return true  (fail open)
+    const-string "Denying spoofed package "
+    ...
+    const-string "ExtendedAccess"
+    invoke-static Log;->w(...)I
+    # then goto loop-continuation (the `continue`)
```

No other class changed. Nothing else was touched.

### Build output

```
variant:      MapboxUserRelease   (at HEAD, `default` is com.google.android.gms)
package:      app.revanced.android.gms
versionCode:  250932007           (installed is 250932004 -> higher, so an update)
versionName:  0.3.13.3.250932-3 (347ef58)-user
size:         105,055,077 B unsigned / 105,325,694 B signed
sha256 (signed): a54c2493dab93328e0cfe72a4eb37542280b83b605481f7b3077a06fecb6e451
signed with:  ~/.revanced/gmscore.keystore  (CN=GmsCore Local Build, RSA-4096)
              password in ~/.revanced/gmscore.keystore.pass (mode 600)
```

Verifies v1 + v2 + v3. **Do not lose that keystore** — future updates must be signed with
the same key or `adb install -r` will fail.

### Remaining caveat before installing

This fix only bites when the spoof target is **not installed**. In this setup the spoof
target (`com.google.android.youtube`) is installed but **disabled**. Disabled packages still
have a `PackageInfo`, and GmsCore targets SDK 29 so package visibility does not restrict it —
so the deny branch should never be taken and behaviour should be unchanged. That is a
reasoned expectation, **not a verified fact**; it can only be confirmed by installing and
checking that YouTube still reaches Google APIs. If it breaks, re-enabling the stock YouTube
app is the first thing to try.
