#!/usr/bin/env bash
# Refuse to release a commit whose CI run is not green.
#
#   scripts/release/check_ci_gate.sh <commit-sha>
#
# Adapted from Syrtis (Nanako0129/TokenBar-Native, scripts/check_ci_gate.sh),
# reduced to limpet's single `CI` workflow (ci.yml).
#
# CI does not run on tags, so without this a tag on the wrong commit, or one
# pushed before main's run finishes, would reach the build and the signing
# key with no CI result in between. The newest push run of ci.yml on main for
# this exact commit must have concluded `success`.
#
# A mistake guard, not a security boundary: the tagged commit carries this
# script and release.yml. The Environment's deployment policy and the
# ancestor-of-main check in release.yml are the controls.
#
# Waits while the run is queued or in progress (up to CI_GATE_TIMEOUT s) and
# while none exists yet (up to CI_GATE_GRACE s: a tag pushed right after a
# merge can arrive before GitHub creates the run). Anything else that is not
# an explicit success fails, including an API error (3 in a row).
#
# Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

sha="${1:-}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
interval="${CI_GATE_INTERVAL:-30}"
timeout="${CI_GATE_TIMEOUT:-1800}"
grace="${CI_GATE_GRACE:-300}"
wf=ci.yml

if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::check_ci_gate: expected a 40-character commit SHA, got '$sha'"
  exit 2
fi

recovery="Once the CI run for $sha is green, re-run this Release run. Tag the merge commit on main (CI starts only for the head commit of a push), not a commit inside the merged branch. If the tag is on the wrong commit, it needs a new tag."

start=$(date +%s)
api_failures=0
while :; do
  elapsed=$(( $(date +%s) - start ))
  if ! body=$(gh api "repos/$repo/actions/workflows/$wf/runs?head_sha=$sha&event=push&branch=main&per_page=100") \
     || ! line=$(jq -er '
        [.workflow_runs[] | select(.head_sha == $sha and .head_branch == "main" and .event == "push")]
        | if length == 0 then "none"
          else (sort_by(.created_at) | last | [.status, (.conclusion // "none"), .html_url] | @tsv)
          end' --arg sha "$sha" <<<"$body"); then
    api_failures=$((api_failures + 1))
    if (( api_failures >= 3 )); then
      echo "::error::check_ci_gate: could not read the runs of $wf for $sha from the GitHub API (3 attempts)."
      echo "$recovery"
      exit 1
    fi
    echo "check_ci_gate: could not read the runs of $wf; retrying (${api_failures}/3)."
    sleep "$interval"
    continue
  fi
  api_failures=0
  IFS=$'\t' read -r status conclusion url <<<"$line"
  if [[ "$status" == "none" ]]; then
    if (( elapsed >= grace )); then
      echo "::error::check_ci_gate: no push run of $wf on main for $sha after ${grace}s."
      echo "$recovery"
      exit 1
    fi
    echo "check_ci_gate: $wf has no run for $sha yet (waited ${elapsed}s of ${grace}s)."
  elif [[ "$status" != "completed" ]]; then
    if (( elapsed >= timeout )); then
      echo "::error::check_ci_gate: $wf for $sha is still $status after ${timeout}s: $url"
      echo "$recovery"
      exit 1
    fi
    echo "check_ci_gate: $wf for $sha is $status (waited ${elapsed}s): $url"
  elif [[ "$conclusion" == "success" ]]; then
    echo "check_ci_gate: $wf for $sha passed: $url"
    exit 0
  elif [[ "$conclusion" == "cancelled" ]]; then
    id="${url##*/}"
    echo "::error::check_ci_gate: $wf for $sha was cancelled: $url"
    echo "Re-run that CI run (gh run rerun $id), wait for it to pass, then re-run this Release run."
    exit 1
  else
    echo "::error::check_ci_gate: $wf for $sha concluded '$conclusion': $url"
    echo "$recovery"
    exit 1
  fi
  sleep "$interval"
done
