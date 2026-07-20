#!/usr/bin/env bash
set -euo pipefail

readonly TYPES='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'
readonly BRANCH_TYPES="$TYPES|sandbox"
readonly HEADER_MAX_LENGTH=100
readonly WORKFLOW_PATH_PREFIX='.github/workflows/'

errors=()

add_error() {
  errors+=("$1")
}

# GitHub logins are case-insensitive, and this script must stay portable to the bash 3.2 that
# ships on macOS, so lowercase through tr rather than ${var,,}.
to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

list_contains() {
  local needle="$1" haystack="$2" item
  [[ -n "$needle" ]] || return 1
  needle="$(to_lower "$needle")"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    [[ "$(to_lower "$item")" == "$needle" ]] && return 0
  done <<< "$haystack"
  return 1
}

# Extracts individual @user owners. Team handles (@org/team) are ignored: this organization defines
# no teams, and a team handle cannot be resolved to a reviewer set with `pull-requests: read` alone.
parse_code_owners() {
  awk '{
    sub(/#.*/, "")
    for (i = 2; i <= NF; i++) {
      if (substr($i, 1, 1) == "@" && index($i, "/") == 0) print substr($i, 2)
    }
  }' | sort -fu
}

# The API returns reviews in chronological order, so the last non-comment state per reviewer is
# their current one. An approval that was later dismissed or replaced by changes-requested must not
# count, which is why this cannot simply grep for APPROVED.
latest_approvers() {
  awk -F'\t' '
    $2 != "COMMENTED" { latest[tolower($1)] = $2 }
    END { for (login in latest) if (latest[login] == "APPROVED") print login }
  ' | sort -fu
}

# Pure decision logic, kept free of network access so --self-test can exercise every branch.
validate_workflow_review() {
  local changed_files="$1" owners="$2" approvers="$3" author="$4"
  local owner eligible_owner_exists=0

  grep -q "^${WORKFLOW_PATH_PREFIX}" <<< "$changed_files" || return 0

  while IFS= read -r owner; do
    [[ -n "$owner" ]] || continue
    if [[ -n "$author" ]] && [[ "$(to_lower "$owner")" == "$(to_lower "$author")" ]]; then
      continue
    fi
    eligible_owner_exists=1
    if list_contains "$owner" "$approvers"; then
      return 0
    fi
  done <<< "$owners"

  # No code owner other than the author exists, so no eligible reviewer exists either. The sole
  # owner already holds the whole trust boundary and requiring the impossible would only deadlock
  # workflow maintenance. This is a deliberate fail-open on single-owner repositories.
  (( eligible_owner_exists == 0 )) && return 0

  add_error "Pull requests that modify ${WORKFLOW_PATH_PREFIX}** require an approving review from a code owner other than the author."
}

validate_branch() {
  local branch="$1"

  if [[ "$branch" == dependabot/* ]]; then
    return
  fi

  if [[ ! "$branch" =~ ^($BRANCH_TYPES)/[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    add_error "Branch '$branch' must use <category>/<lowercase-kebab-case-description>."
  fi
}

validate_header() {
  local label="$1"
  local header="$2"

  if (( ${#header} > HEADER_MAX_LENGTH )); then
    add_error "$label exceeds $HEADER_MAX_LENGTH characters."
  fi

  if [[ ! "$header" =~ ^($TYPES)(\([a-z0-9]+(-[a-z0-9]+)*\))?(!)?:\ [a-z0-9].+[^.]$ ]]; then
    add_error "$label must use type(scope): concise lowercase summary without a trailing period."
  fi
}

validate_body() {
  local body_file="$1"
  local output

  if ! output="$(awk '
    function strip_comments(text, start, finish, before, after) {
      while (1) {
        if (in_comment) {
          finish = index(text, "-->")
          if (!finish) return ""
          text = substr(text, finish + 3)
          in_comment = 0
        }

        start = index(text, "<!--")
        if (!start) return text

        before = substr(text, 1, start - 1)
        after = substr(text, start + 4)
        finish = index(after, "-->")
        if (finish) {
          text = before substr(after, finish + 3)
        } else {
          in_comment = 1
          return before
        }
      }
    }

    BEGIN {
      required[1] = "Summary"
      required[2] = "Context"
      required[3] = "Validation"
      required[4] = "Impact and rollback"
      expected = 1
      failed = 0
    }

    {
      line = $0
      sub(/\r$/, "", line)
      line = strip_comments(line)

      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      if (substr(trimmed, 1, 3) == "```" || substr(trimmed, 1, 3) == "~~~") {
        in_fence = !in_fence
        next
      }
      if (in_fence) next

      if (line ~ /^##[[:space:]]+/) {
        heading = line
        sub(/^##[[:space:]]+/, "", heading)
        sub(/[[:space:]]+$/, "", heading)
        current = heading

        for (i = 1; i <= 4; i++) {
          if (heading == required[i]) {
            count[i]++
            if (i != expected) {
              print "Required section is out of order: ## " heading
              failed = 1
            } else {
              expected++
            }
          }
        }
        next
      }

      for (i = 1; i <= 4; i++) {
        if (current == required[i]) {
          visible = line
          gsub(/<[^>]*>/, "", visible)
          gsub(/[[:space:][:punct:]]/, "", visible)
          if (length(visible) >= 3) filled[i] = 1
        }
      }
    }

    END {
      for (i = 1; i <= 4; i++) {
        if (count[i] == 0) {
          print "Missing required section: ## " required[i]
          failed = 1
        } else if (count[i] > 1) {
          print "Duplicate required section: ## " required[i]
          failed = 1
        } else if (!filled[i]) {
          print "Required section is empty: ## " required[i]
          failed = 1
        }
      }
      exit failed
    }
  ' "$body_file" 2>&1)"; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && add_error "$line"
    done <<< "$output"
  fi
}

# Assertions must report and record rather than rely on `set -e`. A bare `[[ ... ]]` inside a
# function does not abort the script here, so every assertion in this suite was previously
# unenforced: the suite passed even when a validator was broken outright.
self_test_failures=0

expect_error_count() {
  local label="$1" expected="$2" actual="${#errors[@]}"
  if (( actual != expected )); then
    printf 'SELF-TEST FAILED: %s (expected %d error(s), got %d)\n' "$label" "$expected" "$actual" >&2
    self_test_failures=$(( self_test_failures + 1 ))
  fi
}

expect_equal() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'SELF-TEST FAILED: %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual" >&2
    self_test_failures=$(( self_test_failures + 1 ))
  fi
}

self_test() {
  local temporary_directory
  temporary_directory="$(mktemp -d)"
  trap 'rm -rf "$temporary_directory"' RETURN
  self_test_failures=0

  errors=()
  validate_branch "feat/contact-import"
  validate_branch "sandbox/rewe"
  validate_branch "dependabot/npm_and_yarn/zod-4.0.0"
  expect_error_count "conventional and dependabot branches are accepted" 0

  errors=()
  validate_branch "feature/contact-import"
  validate_branch "feat/Contact_import"
  expect_error_count "unknown type and non-kebab-case branches are rejected" 2

  errors=()
  validate_header "Header" "feat(contacts): add contact import"
  validate_header "Header" "fix!: prevent duplicate messages"
  validate_header "Header" "chore(release): 1.4.0"
  expect_error_count "conventional headers are accepted" 0

  errors=()
  validate_header "Header" "Feature: Add contact import"
  validate_header "Header" "feat: add contact import."
  validate_header "Header" "feat(Bad Scope): add contact import"
  expect_error_count "malformed headers are rejected" 3

  printf '%s\n' \
    '## Summary' 'Adds contact import.' '' \
    '## Context' 'Customers need a faster import.' '' \
    '## Validation' 'Ran the unit tests.' '' \
    '## Impact and rollback' 'Revert the pull request.' > "$temporary_directory/valid-body"
  errors=()
  validate_body "$temporary_directory/valid-body"
  expect_error_count "a complete, ordered body is accepted" 0

  printf '%s\n' \
    '## Context' 'Out of order.' '' \
    '## Summary' '<!-- empty -->' '' \
    '## Validation' 'Ran tests.' '' \
    '## Validation' 'Duplicate.' > "$temporary_directory/invalid-body"
  errors=()
  validate_body "$temporary_directory/invalid-body"
  if (( ${#errors[@]} < 4 )); then
    printf 'SELF-TEST FAILED: %s (expected at least 4 errors, got %d)\n' \
      "an out-of-order, empty, duplicated, incomplete body is rejected" "${#errors[@]}" >&2
    self_test_failures=$(( self_test_failures + 1 ))
  fi

  local two_owners docs_only workflow_change
  two_owners=$'benjiwagner\neljulsi'
  docs_only=$'README.md\nplatform/github.md'
  workflow_change=$'.github/workflows/knowledge-base.yml\nREADME.md'

  errors=()
  validate_workflow_review "$docs_only" "$two_owners" "" "eljulsi"
  expect_error_count "a pull request touching no workflow file is unaffected" 0

  errors=()
  validate_workflow_review "$workflow_change" "$two_owners" "" "eljulsi"
  expect_error_count "a workflow change with no approval is rejected" 1

  errors=()
  validate_workflow_review "$workflow_change" "$two_owners" "eljulsi" "eljulsi"
  expect_error_count "self-approval does not satisfy the workflow guard" 1

  errors=()
  validate_workflow_review "$workflow_change" "$two_owners" "some-contributor" "eljulsi"
  expect_error_count "approval from a non-code-owner does not satisfy the workflow guard" 1

  errors=()
  validate_workflow_review "$workflow_change" "$two_owners" "BenjiWagner" "eljulsi"
  expect_error_count "approval from another code owner satisfies it, case-insensitively" 0

  errors=()
  validate_workflow_review "$workflow_change" "benjiwagner" "" "benjiwagner"
  expect_error_count "a sole-code-owner repository has no eligible reviewer and skips" 0

  errors=()
  validate_workflow_review "docs/.github/workflows/example.yml" "$two_owners" "" "eljulsi"
  expect_error_count "the workflow prefix is anchored to the start of the path" 0

  expect_equal "CODEOWNERS parsing keeps users and drops comments, patterns, and team handles" \
    $'benjiwagner\neljulsi' \
    "$(printf '%s\n' '# owners' '*  @benjiwagner @eljulsi' '/docs/ @customermates/writers' | parse_code_owners)"

  expect_equal "only each reviewer's latest non-comment review state counts" \
    $'charlie\ndelta' \
    "$(printf '%s\t%s\n' \
      'alpha' 'APPROVED' \
      'alpha' 'DISMISSED' \
      'bravo' 'APPROVED' \
      'bravo' 'CHANGES_REQUESTED' \
      'charlie' 'CHANGES_REQUESTED' \
      'charlie' 'APPROVED' \
      'delta' 'APPROVED' \
      'delta' 'COMMENTED' | latest_approvers)"

  if (( self_test_failures > 0 )); then
    printf '%s\n' "Repository policy self-test failed: ${self_test_failures} assertion(s)." >&2
    return 1
  fi

  printf '%s\n' "Repository policy self-test passed."
}

if [[ "${1:-}" == "--self-test" ]]; then
  # Explicit, because a nonzero return from self_test does not abort under `set -e` here.
  self_test || exit 1
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

readonly pr_number="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
readonly pr_author="$(jq -r '.pull_request.user.login // ""' "$GITHUB_EVENT_PATH")"
readonly head_sha="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
readonly head_branch="$(jq -r '.pull_request.head.ref // empty' "$GITHUB_EVENT_PATH")"
readonly base_sha="$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")"
readonly title="$(jq -r '.pull_request.title // ""' "$GITHUB_EVENT_PATH")"

: "${pr_number:?Pull request number is missing from the event}"
: "${head_sha:?Pull request head SHA is missing from the event}"
: "${head_branch:?Pull request head branch is missing from the event}"

validate_branch "$head_branch"

validate_header "Pull request title" "$title"

body_file="$(mktemp)"
commits_file="$(mktemp)"
trap 'rm -f "$body_file" "$commits_file"' EXIT
jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH" > "$body_file"
if [[ "$pr_author" != "dependabot[bot]" ]]; then
  validate_body "$body_file"
fi

gh api --paginate \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/commits?per_page=100" \
  --jq '.[] | [.sha, (.commit.message | split("\n")[0])] | @tsv' > "$commits_file"

while IFS=$'\t' read -r commit_sha commit_header; do
  [[ -n "$commit_sha" ]] || continue
  validate_header "Commit ${commit_sha:0:12}" "$commit_header"
done < "$commits_file"

# Workflow-tamper guard. The `ci` check is defined by a workflow file that GitHub evaluates from
# the pull-request head, so a pull request can rewrite what its own required check executes. This
# check runs from the base branch inside the bypass-free integrity layer, which is what makes it
# able to constrain that. CODEOWNERS and the reviews are both read from the base ref for the same
# reason: reading either from the head would let a pull request nominate its own approvers.
changed_files="$(gh api --paginate \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/files?per_page=100" \
  --jq '.[].filename')"

if grep -q "^${WORKFLOW_PATH_PREFIX}" <<< "$changed_files"; then
  code_owners=""
  if [[ -n "$base_sha" ]]; then
    code_owners="$(gh api \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      --header "Accept: application/vnd.github.raw" \
      "repos/${GITHUB_REPOSITORY}/contents/.github/CODEOWNERS?ref=${base_sha}" 2>/dev/null \
      | parse_code_owners || true)"
  fi

  approving_reviewers="$(gh api --paginate \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/reviews?per_page=100" \
    --jq '.[] | [.user.login, .state] | @tsv' \
    | latest_approvers)"

  validate_workflow_review "$changed_files" "$code_owners" "$approving_reviewers" "$pr_author"
fi

if (( ${#errors[@]} > 0 )); then
  printf '%s\n' "Repository policy failed:" >&2
  printf '  - %s\n' "${errors[@]}" >&2
  exit 1
fi

printf '%s\n' "Repository policy passed"
