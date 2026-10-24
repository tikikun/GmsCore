#!/usr/bin/env bash
# Rebuild GmsCore from this tree and verify it against an official release APK.
#
# Reproducible as of v0.3.13.2.250932: the rebuilt dex is byte-identical to the
# official APK (33,098/33,098 smali files, 0 differing).
#
# Usage:
#   ./scripts/rebuild-and-verify.sh [--official <official.apk>] [--variant MmmTarget]
#
# Defaults: variant MapboxDefaultRelease, output auto-detected from build/outputs.
set -uo pipefail

VARIANT="MapboxDefaultRelease"
OFFICIAL=""
TASKS_PREFIX=":play-services-core:"
while [ $# -gt 0 ]; do
  case "$1" in
    --official) OFFICIAL="$2"; shift 2 ;;
    --variant)  VARIANT="$2";  shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT" || exit 1

: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export ANDROID_HOME
SDK_BUILD_TOOLS=$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -1)

echo "== environment"
echo "  repo:      $REPO_ROOT"
echo "  commit:    $(git log --oneline -1 2>/dev/null)"
echo "  ANDROID_HOME: $ANDROID_HOME"
echo "  build-tools:  ${SDK_BUILD_TOOLS:-<none found>}"
echo

# A JDK 17 is required by AGP; honour JAVA_HOME if set, else try Homebrew.
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
fi
echo "  JAVA_HOME: ${JAVA_HOME:-<unset>}"
echo

echo "== building ${TASKS_PREFIX}assemble${VARIANT}"
./gradlew --no-daemon "${TASKS_PREFIX}assemble${VARIANT}" || {
  echo
  echo "BUILD FAILED."
  echo "Note: variant naming is <maps><target>, e.g. MapboxDefaultRelease — NOT DefaultMapboxRelease."
  exit 1
}

# Output naming: app.revanced.android.gms-<versionCode>.apk
BUILT=$(find play-services-core/build/outputs/apk -name "*.apk" -newermt '-2 hours' 2>/dev/null | head -1)
if [ -z "$BUILT" ]; then
  BUILT=$(find play-services-core/build/outputs/apk -name "app.revanced.android.gms-*.apk" 2>/dev/null | head -1)
fi
[ -n "$BUILT" ] || { echo "could not locate built APK"; exit 1; }

echo
echo "== built APK"
echo "  path: $BUILT"
echo "  size: $(wc -c < "$BUILT") bytes"
echo "  sha256: $(shasum -a 256 "$BUILT" | awk '{print $1}')"
echo "  (release output is UNSIGNED — the official APK carries META-INF/*.RSA)."
echo

if [ -z "$OFFICIAL" ]; then
  echo "No --official APK given; skipping equivalence check."
  echo "Re-run with: --official app.revanced.android.gms-<code>-signed.apk"
  exit 0
fi

[ -f "$OFFICIAL" ] || { echo "official APK not found: $OFFICIAL"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need unzip; need java

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/off" "$WORK/mine"
( cd "$WORK/off"  && unzip -qo "$OFFICIAL" 'classes*.dex' )
( cd "$WORK/mine" && unzip -qo "$BUILT"    'classes*.dex' )

echo "== equivalence check"

# 1. dex class sets (dexdump, if available)
DEXDUMP=""
[ -n "$SDK_BUILD_TOOLS" ] && [ -x "${SDK_BUILD_TOOLS}dexdump" ] && DEXDUMP="${SDK_BUILD_TOOLS}dexdump"
if [ -n "$DEXDUMP" ]; then
  for side in off mine; do
    ( cd "$WORK/$side" && for f in classes*.dex; do
        "$DEXDUMP" -f "$f" 2>/dev/null | grep -oE "Class descriptor.*: '[^']*'" | sed "s/.*: '//;s/'\$//"
      done | sort -u > "$WORK/$side.classes.txt" )
  done
  o=$(wc -l < "$WORK/off.classes.txt"); m=$(wc -l < "$WORK/mine.classes.txt")
  if diff -q "$WORK/off.classes.txt" "$WORK/mine.classes.txt" >/dev/null; then
    echo "  class sets: IDENTICAL ($m classes)"
  else
    echo "  class sets: DIFFER (official $o, rebuilt $m)"
    diff "$WORK/off.classes.txt" "$WORK/mine.classes.txt" | head -20
  fi
else
  echo "  class sets: skipped (dexdump not found)"
fi

# 2. zip entry / CRC comparison
python3 - "$OFFICIAL" "$BUILT" <<'PY'
import sys, zipfile, collections
official, built = sys.argv[1], sys.argv[2]
a, b = zipfile.ZipFile(official), zipfile.ZipFile(built)
na, nb = set(a.namelist()), set(b.namelist())
print(f"  entries: official={len(na)} rebuilt={len(nb)} added={len(nb-na)} removed={len(na-nb)}")
for n in sorted(nb - na)[:5]: print(f"    only in rebuilt: {n}")
for n in sorted(na - nb)[:5]: print(f"    only in official: {n}")
diff = [n for n in na & nb if a.getinfo(n).CRC != b.getinfo(n).CRC]
c = collections.Counter(n.split('/')[0] if '/' in n else n for n in diff)
print(f"  entries with differing CRC: {len(diff)}  {dict(c)}")
nondex = [n for n in diff if not n.endswith('.dex') and not n.startswith('META-INF/')]
if nondex:
    print(f"  non-dex differences ({len(nondex)}): {nondex[:8]}")
    print("    (PNG-only differences are expected: aapt2 compression varies between build-tools)")
PY

# 3. smali-level identity, if baksmali is reachable
BAKSMALI_JAR="${BAKSMALI_JAR:-}"
if [ -n "$BAKSMALI_JAR" ] && [ -f "$BAKSMALI_JAR" ]; then
  for side in off mine; do
    for f in "$WORK/$side"/classes*.dex; do
      java -cp "$BAKSMALI_JAR" com.android.tools.smali.baksmali.Main d "$f" -o "$WORK/sm$side" >/dev/null 2>&1
    done
  done
  n=$(diff -rq "$WORK/smoff" "$WORK/smmine" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then
    echo "  smali trees: IDENTICAL ($(find "$WORK/smoff" -name '*.smali' | wc -l | tr -d ' ') files, 0 differing)"
  else
    echo "  smali trees: $n differing files (first few:)"
    diff -rq "$WORK/smoff" "$WORK/smmine" 2>/dev/null | head -5
  fi
else
  echo "  smali trees: skipped (set BAKSMALI_JAR=/path/to/jar/with/baksmali)"
fi

echo
echo "Done. A matching dex means the official APK's code corresponds to this source tree."
