set -uo pipefail
cd "$(dirname "$0")"
root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

mapfile -t JDKS < <(
  { env | sed -n 's/^JAVA_HOME_[0-9]*_[A-Za-z0-9]*=//p'
    ls -d /usr/lib/jvm/*/ 2>/dev/null | sed 's:/$::'
    [ -n "${JAVA_HOME:-}" ] && echo "$JAVA_HOME"
  } | sort -u | while read -r d; do [ -x "$d/bin/javac" ] && echo "$d"; done
)
[ ${#JDKS[@]} -eq 0 ] && { echo "no JDK found"; exit 1; }
echo "JDKs: ${JDKS[*]}"

while IFS=$'\t' read -r url branch jarpath; do
  case ${url:-} in ''|\#*) continue;; esac
  name=$(basename "$url" .git)

  sha=$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | cut -f1)
  if [ -z "$sha" ]; then echo "SKIP $name: no branch $branch"; fail=1; continue; fi

  out=$root/jars/$name/$sha
  if [ -d "$out" ]; then echo "SKIP $name@${sha:0:8}: already built"; continue; fi

  echo "BUILD $name ($branch) @${sha:0:8}"
  src=$work/$name
  git clone --depth 1 --recurse-submodules --branch "$branch" "$url" "$src" >/dev/null 2>&1 || {
    echo "FAIL $name: clone"; rm -rf "$src"; fail=1; continue; }
  chmod +x "$src/gradlew" 2>/dev/null
  if [ -f "$src/gradlew" ]; then gw=(./gradlew)
  elif [ -f "$src/gradle/wrapper/gradle-wrapper.jar" ]; then
    gw=(java -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain)
  else echo "FAIL $name: no gradle wrapper"; rm -rf "$src"; fail=1; continue; fi

  built=""
  for target in assemble 1.8.9:assemble 1.8.9-ornithe:assemble; do
    for jdk in "${JDKS[@]}"; do
      ( cd "$src" && JAVA_HOME=$jdk PATH=$jdk/bin:$PATH \
          "${gw[@]}" "$target" --no-daemon --stacktrace \
      ) > "$work/$name.log" 2>&1 </dev/null && { built="$jdk $target"; break 2; }
    done
  done
  if [ -z "$built" ]; then
    echo "FAIL $name: gradle on every JDK"
    grep -A6 'What went wrong' "$work/$name.log" | head -10
    rm -rf "$src"; fail=1; continue
  fi

  mapfile -t jars < <(find "$src" -path '*/build/libs/*.jar' \
    ! -name '*-sources.jar' ! -name '*-javadoc.jar' ! -name '*-dev.jar' \
    ! -name '*-dev-*.jar' ! -name '*-slim.jar' ! -name '*-namedElements*.jar' | sort)
  # Multi-module repos (OneConfig) build library jars beside the one we actually want;
  # the optional third repos.txt column restricts which build dir counts.
  if [ -n "${jarpath:-}" ]; then
    mapfile -t jars < <(printf '%s\n' "${jars[@]}" | grep -F "$jarpath")
  fi
  # A repo whose branch is still multi-version emits a jar per Minecraft version.
  mapfile -t only189 < <(printf '%s\n' "${jars[@]}" | grep -F '1.8.9')
  [ ${#only189[@]} -gt 0 ] && jars=("${only189[@]}")
  if [ ${#jars[@]} -eq 0 ]; then echo "FAIL $name: no jar produced"; rm -rf "$src"; fail=1; continue; fi

  mkdir -p "$out"
  cp "${jars[@]}" "$out/"
  { echo "$branch"; ( cd "$src" && git log -1 --format='%H%n%cI%n%s' ); } > "$out/COMMIT.txt"
  ( cd "$out" && sha256sum *.jar > SHA256SUMS )
  rm -rf "$src"
  echo "OK $name@${sha:0:8}: ${#jars[@]} jar(s) via ${built##*/}"
done < repos.txt

# INDEX.txt lists only the newest build of each repo (by commit date).
for repo in jars/*/; do
  for b in "$repo"*/; do
    [ -f "$b/COMMIT.txt" ] && printf '%s\t%s\n' "$(sed -n 3p "$b/COMMIT.txt")" "$b"
  done | sort -r | head -1 | cut -f2
done | xargs -r -I{} find {} -name '*.jar' | sort > INDEX.txt
exit $fail
