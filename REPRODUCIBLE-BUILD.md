# Reproducible build & verification (local fork notes)

Notes added on top of upstream `ReVanced/GmsCore`. **Upstream files are untouched** — this
document and `scripts/rebuild-and-verify.sh` are the only additions, so `main` can still be
synced with upstream cleanly.

Purpose: this fork exists so a known-good tree survives upstream disappearing (cf.
`ReVanced/revanced-patches`, DMCA-removed from GitHub in 2026-03) and so rebuilds are
repeatable and checkable.

---

## Verified state

Rebuilt at tag **`v0.3.13.2.250932`** and compared against the official release APK
(`app.revanced.android.gms-250932004-signed.apk`, sha256 `62119f04…`):

| Metric | Result |
|---|---|
| versionCode / versionName | `250932004` / `0.3.13.2.250932` — identical |
| Classes (`dexdump`) | 33,098 — identical set |
| smali files (`baksmali`) | 33,098 — **`diff -rq` reports 0 differing files** |
| Dex, native libs, `resources.arsc`, manifest | CRC-identical |
| 11 `res/*.png` | differ by 1–3 bytes of compression; **pixel-identical** |
| `META-INF/*` | present only in official (release output here is unsigned) |

**Conclusion: the official APK's code corresponds to this source tree.** Reproducibility
proves binary↔source correspondence; it does not by itself prove the source is benign.

## Requirements

- JDK **17** (AGP requirement; Java 21+ may fail)
- Android SDK with **build-tools 34.0.0** and **platform android-35**
- Gradle wrapper 8.11.1 (downloaded automatically)
- No NDK, **no GitHub Packages credentials** — dependencies resolve from `mavenCentral()`
  and `google()` only
- `python3` for the zip comparison; `dexdump` from build-tools; optionally `baksmali`

## Build

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

git checkout v0.3.13.2.250932        # must be the tag, on a clean tree
./gradlew --no-daemon :play-services-core:assembleMapboxDefaultRelease
```

Verified timing: **9m35s**, 2916 actionable tasks (2217 executed, 699 from cache).

### Gotchas

1. **Variant naming is `<maps><target>`**, not `<target><maps>`.
   Correct: `assembleMapboxDefaultRelease`. Wrong: `assembleDefaultMapboxRelease`
   (fails with "task not found").
2. **Flavors:** `maps` ∈ {`hms`, `mapbox`, `vtm`}, `target` ∈ {`default`, `huawei`,
   `huaweilh`, `user`}. The ReVanced release matches `mapbox` + `default` — it ships
   `libmapbox-gl.so` and the package is `app.revanced.android.gms` (the `user` flavor
   switches `applicationId` to `org.microg.gms`).
3. **Release output is unsigned.** Sign it yourself if you intend to install
   (`apksigner sign …`). Signing with your own key changes the app signature, so
   installing over the official build requires an uninstall first — which discards the
   stored Google session in GmsCore.
4. `versionName` is derived from `git describe --tags`. A `-dirty` or `-<n>` suffix in the
   output means the tree was modified or ahead of the tag; a clean build at the tag yields
   exactly `0.3.13.2.250932`.
5. `compileSdk 35` triggers an AGP "unsupported compileSdk" warning — harmless.

## Verify a rebuild against an official APK

```bash
./scripts/rebuild-and-verify.sh \
    --official /path/to/app.revanced.android.gms-250932004-signed.apk
```

Environment overrides: `ANDROID_HOME`, `JAVA_HOME`, and `BAKSMALI_JAR` (any jar containing
`com.android.tools.smali.baksmali.Main`, e.g. a `revanced-cli-*-all.jar`) to enable the
smali-level comparison. Without `BAKSMALI_JAR` it still checks class sets and zip CRCs.

The script prints a verdict per layer: class sets, zip entries/CRCs, smali trees.

## Syncing with upstream

```bash
git remote add upstream https://github.com/ReVanced/GmsCore.git   # if absent
git fetch upstream --tags
git checkout main && git merge upstream/main
```

Because the only local additions are this document and one script, merges should stay
conflict-free. If upstream ever edits those paths, prefer `-X ours` for this doc.

## Rebuilding other variants

```bash
./scripts/rebuild-and-verify.sh --variant HuaweiDefaultRelease   # the -hw build
./scripts/rebuild-and-verify.sh --variant MapboxUserRelease      # org.microg.gms, no rebrand
```

Note the ReVanced rebrand lives in the `default`/`huawei` target flavors; `user` produces
upstream microG's own package id.
