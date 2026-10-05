#!/usr/bin/env bash
# CI checks, identical locally and on GitHub Actions.
# Needs python3-yaml, python3-jinja2, shellcheck and docker. Locally: DOCKER="sudo docker" ./ci/check.sh
set -u
cd "$(dirname "$0")/.."
DOCKER=${DOCKER:-docker}
IMG=quay.io/frrouting/frr:10.2.1
fail=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "== Python scripts compile =="
for f in netbox/*.py; do python3 -m py_compile "$f" && ok "$f" || bad "$f"; done

echo "== YAML files parse =="
for f in mini-iliad.clab.yml .github/workflows/*.yml; do
  python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" && ok "$f" || bad "$f"
done

echo "== Shell scripts: no shellcheck errors =="
for f in ./*.sh ci/*.sh configs/*.sh; do shellcheck -S error "$f" && ok "$f" || bad "$f"; done

echo "== Generated configs match snapshot + template + policy =="
python3 netbox/render.py --snapshot netbox/snapshot.json > /dev/null
if git diff --quiet -- generated/; then ok "generated/ is up to date"; else bad "generated/ differs, re-render and commit"; git --no-pager diff --stat -- generated/; fi

echo "== FRR syntax check (vtysh dry run in the official FRR image) =="
$DOCKER pull -q "$IMG" > /dev/null || bad "could not pull $IMG"
for f in generated/*.conf configs/arelion.conf configs/cogent.conf configs/internet.conf configs/fastweb.conf configs/netflix.conf configs/rs.conf; do
  out=$($DOCKER run --rm -v "$PWD/$f:/tmp/c.conf:ro" -v "$PWD/configs/vtysh.conf:/etc/frr/vtysh.conf:ro" "$IMG" vtysh -C -f /tmp/c.conf 2>&1)
  rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then ok "$f"; else bad "$f (exit $rc)"; echo "$out" | head -5 | sed 's/^/      /'; fi
done

echo "== $fail check(s) failed =="
exit $fail
