#!/bin/bash
# test_grafana_split.sh - real test of the per-component Grafana quarterly build, without touching the
# current quarter. Run as ansible on ansible-forge:   bash test_grafana_split.sh
#
# Builds a throwaway quarter (fy27q1test) seeded from the current one, with scans on, and idrac forced
# to fail after its images are delivered, so one run tests both paths on real images:
#   grafana, prometheus, nginx  -> built, scanned, signed this run
#   idrac                       -> falls back to the current quarter's release (images, signatures, scans)
# Then checks the result and prints a report:
#   - each component's result, versions.env, fallback.env, the rendered compose image lines
#   - every delivered image's signature verifies (provenance/signatures)
#   - provenance holds exactly one run's scans, every scan file has a signature
#   - the current quarter's files are unchanged (listing before/after)
# Always puts back what the build changes outside the test quarter: the 'current' symlink and the
# dashboard files it writes (pipeline_quarterly_*.prom). The test quarter stays for you to look at;
#   bash test_grafana_split.sh --cleanup     removes it (files/grafana/fy27q1test, build/grafana_stack/*/fy27q1test)
# Takes about as long as a quarterly Grafana build (~40 min). Log: /opt/ansible/logs/test_grafana_split-<date>.log

set -uo pipefail
[ "$(id -un)" = ansible ] || { echo "run this as ansible"; exit 1; }
TQ=fy27q1test
FILES=/opt/ansible/files/grafana
BUILD=/opt/ansible/build/grafana_stack
TEXTFILE=/var/lib/node_exporter/textfile
eval "$(/opt/ansible/files/common/scripts/determine_quarters.sh)"     # sets quarter=<current>
CQ=$quarter

cleanup_test() {
  sudo rm -rf "${FILES:?}/$TQ" "$BUILD"/*/"$TQ"
  echo "removed $FILES/$TQ and $BUILD/*/$TQ"
}
if [ "${1:-}" = --cleanup ]; then cleanup_test; exit 0; fi

[ -d "$FILES/$CQ" ] || { echo "current quarter $FILES/$CQ not found"; exit 1; }
LOG=/opt/ansible/logs/test_grafana_split-$(date +%F-%H%M).log
SNAP=$(mktemp -d -p /opt/ansible/molecule/scratch 2>/dev/null || mktemp -d)
restore() {
  ln -sfn "$FILES/$CQ" "$FILES/current"
  rm -f "$TEXTFILE"/pipeline_quarterly_*.prom
  rm -rf "$SNAP"
}
trap restore EXIT

echo "== test quarter $TQ, seeded from $CQ (log: $LOG)"
[ -e "$FILES/$TQ" ] && { echo "   removing the previous test quarter"; cleanup_test >/dev/null; }
find "$FILES/$CQ" -type f -printf '%P %s %T@\n' | sort > "$SNAP/before"
touch "$SNAP/start"

cd /opt/ansible/nucleus/playbooks
ansible-playbook -i /opt/ansible/vars/inventory.ini build_grafana_stack.yml --vault-password-file ~/vault_pass.txt \
  -e quarter=$TQ -e previous_quarter=$CQ -e '{"quarterly_force_fail": ["idrac"]}' > "$LOG" 2>&1
prc=$?
find "$FILES/$CQ" -type f -printf '%P %s %T@\n' | sort > "$SNAP/after"

T=$FILES/$TQ
ok=0; bad=0
check() { if eval "$2"; then echo "   OK    $1"; ok=$((ok + 1)); else echo "   FAIL  $1"; bad=$((bad + 1)); fi; }

echo
echo "== playbook exit $prc"
grep -oE '"msg": "[a-z_]+: (built|FALLBACK|FAILED)[^"]*' "$LOG" | sed 's/"msg": "/   /'
echo
echo "== versions.env";  sed 's/^/   /' "$T/versions.env" 2>/dev/null
echo "== fallback.env";  sed 's/^/   /' "$T/fallback.env" 2>/dev/null
echo "== compose images"; grep -E '^\s*image:' "$T/docker-compose.yml" 2>/dev/null | sed 's/^ */   /'
echo
echo "== checks"
check "playbook succeeded" '[ $prc -eq 0 ]'
check "grafana, prometheus, nginx built this run" '[ $(grep -cE "\"msg\": \"(grafana|prometheus|nginx_grafana): built " "$LOG") -eq 3 ]'
check "idrac fell back to the $CQ release" 'grep -qE "\"msg\": \"idrac: FALLBACK to [0-9.]+ from $CQ" "$LOG"'
check "fallback.env lists idrac only" '[ "$(grep -v "^#" "$T/fallback.env" | grep -c .)" = 1 ] && grep -q "^IDRAC_VERSION=" "$T/fallback.env"'
check "8 images delivered (ccop + nucleus x 4)" '[ $(ls "$T"/images/{ccop,nucleus}-*.tar.gz 2>/dev/null | wc -l) -eq 8 ]'
check "idrac image is the $CQ one, byte for byte" 'f=$(ls "$T"/images/nucleus-idrac-*.tar.gz | head -1); cmp -s "$f" "$FILES/$CQ/images/$(basename "$f")"'
check "every image signature verifies" 'n=0; for i in "$T"/images/{ccop,nucleus}-*.tar.gz; do sudo gpg --batch --verify "$T/provenance/signatures/$(basename "$i").asc" "$i" 2>/dev/null || n=1; done; [ $n -eq 0 ]'
check "no signatures left in ccop/, nucleus/, container-forge/" '[ -z "$(find "$T"/provenance/{ccop,nucleus,container-forge} -name "*.asc" 2>/dev/null)" ]'
check "one run of scans per built image (no repeats)" '[ -z "$(ls "$T"/provenance/{ccop,nucleus} 2>/dev/null | grep -E "\.vuln\.json$" | sed -E "s/\.[0-9]{8}T[0-9]{6}Z.*//" | sort | uniq -d)" ]'
check "every scan result from this run is signed" 'n=0; for f in $(find "$T"/provenance/{ccop,nucleus,container-forge,grafana-sast} -type f -newer "$SNAP/start" 2>/dev/null); do [ -f "$T/provenance/signatures/$(basename "$f").asc" ] || n=$((n+1)); done; [ $n -eq 0 ]'
check "docker-compose.yml rendered with idrac at the fallback version" 'v=$(sed -n "s/^IDRAC_VERSION=//p" "$T/versions.env"); grep -q "nucleus/idrac:$v" "$T/docker-compose.yml"'
check "$CQ unchanged (every file, size and time)" 'diff -q "$SNAP/before" "$SNAP/after" >/dev/null'
echo
echo "== $ok passed, $bad failed. Test quarter kept at $T - remove it with: bash $0 --cleanup"
[ $bad -eq 0 ]
