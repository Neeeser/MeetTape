#!/bin/bash
# The staged comparison campaign that decides the default local model set.
#
# Three rounds, each a resumable bench invocation under caffeinate, writing
# into one campaign directory. Run a round, read its table, then run the next;
# a killed session loses at most the case in flight, and re-running a round
# picks up where it stopped. Nothing here decides anything: the output is the
# table the decision is made from.
#
#   scripts/bench-campaign.sh diarizers          # round 1: local vs lseend
#   scripts/bench-campaign.sh engines            # round 2: five engines, deciding suite
#   scripts/bench-campaign.sh finals ENGINE/DIARIZER [ENGINE/DIARIZER ...]
#                                                # round 3: chosen combos, 3 repeats
#   scripts/bench-campaign.sh finals-cloud DIARIZER
#                                                # cloud reference rows (needs OPENAI_API_KEY)
#
# Options: --dir DIR (default bench-campaign), --repeats N (finals only, default 3)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$REPO_ROOT/bench-campaign"
ROUND="${1:-}"
shift || true

REPEATS=3
COMBOS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        *) COMBOS+=("$1"); shift ;;
    esac
done

mkdir -p "$DIR"

bench() {
    # caffeinate keeps the machine awake through a multi-hour engine; --resume
    # makes re-running the same command a continuation, not a restart. A
    # nonzero exit is recorded and the campaign continues: a candidate that
    # fails cases is a result, not a reason to skip the candidates after it.
    if ! caffeinate -dims "$REPO_ROOT/scripts/eval.sh" bench "$@" --resume --keep-scratch; then
        echo "CAMPAIGN: '$*' finished nonzero; its failures are in the report above" >&2
    fi
}

case "$ROUND" in
    diarizers)
        # Engine held at the incumbent: a diarizer listens to audio, not to
        # transcripts, so one engine is enough to rank them. Judged on the
        # overlap-heavy suites, where diarizers actually differ.
        for diarizer in local lseend; do
            for suite in ami-overlap icsi notsofar; do
                bench --suite "$suite" --engine parakeet --diarizer "$diarizer" \
                    --out "$DIR/diarizers-$diarizer-$suite.json"
            done
        done
        ;;
    engines)
        # Diarizer fixed at the round-1 winner, passed as the one combo
        # argument, e.g. `engines lseend`. One run per case; repeats are paid
        # only in the finals.
        DIARIZER="${COMBOS[0]:-local}"
        for engine in parakeet cohere whisper canary apple; do
            bench --suite deciding --engine "$engine" --diarizer "$DIARIZER" \
                --out "$DIR/engines-$engine-$DIARIZER.json"
        done
        ;;
    finals)
        if [ ${#COMBOS[@]} -eq 0 ]; then
            echo "finals needs combos, e.g. scripts/bench-campaign.sh finals parakeet/lseend cohere/lseend" >&2
            exit 2
        fi
        for combo in "${COMBOS[@]}"; do
            engine="${combo%%/*}"
            diarizer="${combo##*/}"
            bench --suite deciding --engine "$engine" --diarizer "$diarizer" \
                --repeats "$REPEATS" --out "$DIR/finals-$engine-$diarizer.json"
        done
        ;;
    finals-cloud)
        DIARIZER="${COMBOS[0]:-local}"
        if [ -z "${OPENAI_API_KEY:-}" ]; then
            echo "finals-cloud needs OPENAI_API_KEY" >&2
            exit 2
        fi
        # Reference rows, not candidates: what money buys, next to what the
        # local engines deliver. One repeat; cloud decoding does not vary the
        # way a Neural Engine decode does, and repeats triple the bill.
        bench --suite deciding --engine gpt-transcribe --engine whisper-1 \
            --diarizer "$DIARIZER" --out "$DIR/finals-cloud-$DIARIZER.json"
        bench --suite deciding --engine gpt-4o-transcribe-diarize --diarizer cloud \
            --out "$DIR/finals-cloud-combined.json"
        ;;
    *)
        sed -n '2,18p' "$0"
        exit 2
        ;;
esac

echo ""
echo "round '$ROUND' complete; results in $DIR"
