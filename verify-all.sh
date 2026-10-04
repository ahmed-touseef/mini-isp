#!/usr/bin/env bash
# Full regression suite: runs every verify script and reports PASS or FAIL. Run with sudo.
cd "$(dirname "$0")"
mkdir -p logs
TESTS="verify.sh verify-bgp.sh verify-edge.sh verify-policy.sh verify-ix.sh verify-sr.sh verify-bfd.sh verify-access.sh verify-cgnat.sh verify-dns.sh"
BAD='FAIL|TIMEOUT|LEAKED|LEAK ACCEPTED|NOT rerouted|REACHABLE \(unexpected\)'
fails=0
for t in $TESTS; do
  start=$(date +%s)
  ./$t > logs/${t%.sh}.log 2>&1
  n=$(grep -E "$BAD" logs/${t%.sh}.log | grep -vc "expected")
  dur=$(( $(date +%s) - start ))
  if [ "$n" -eq 0 ]; then
    printf "  PASS  %-18s %4ss\n" "$t" "$dur"
  else
    printf "  FAIL  %-18s %4ss  (%s problem lines, see logs/%s.log)\n" "$t" "$dur" "$n" "${t%.sh}"
    fails=$((fails + 1))
  fi
done
echo "== $fails of $(echo $TESTS | wc -w) test scripts failed =="
exit $fails
