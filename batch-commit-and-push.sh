#!/usr/bin/env bash
set -euo pipefail

# Defaults (overridable via args)
REPO_DIR="repo_big"
ORG="kira-id"
VISIBILITY="public"                # public | private | internal
COMMIT_MSG="chore: batch commit"
DRY_RUN=false
FORCE=false
CREATE_REPOS=true
TOKEN=""                           # optional: for API create + non-interactive HTTPS push
REMOTE_NAME="origin"
OLD_REMOTE_BASE="origin-old"
PARALLEL_JOBS=1                    # number of parallel jobs (1 = sequential)

# Description options
DESC_MODE="auto"                   # auto | template | fixed | skip
DESC_TEMPLATE="{name}"
DESC_FIXED=""
FORCE_DESCRIPTION=true             # overwrite even if already set

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options]

Options:
  --repo-dir PATH                 Default: repo
  --org ORG                       Default: kira-id
  --visibility VIS                Default: public|private|internal (public)
  --message MSG                   Default: "chore: batch commit"
  --token TOKEN                   GitHub token (API create + optional HTTPS push)
  --no-create                     Do not create missing GitHub repos
  --force                         Push with --force-with-lease
  --dry-run                       Print actions only
  -j, --jobs N                    Number of parallel jobs (default: 1)
  -h, --help                      Show help

Description options:
  --desc-mode MODE                auto | template | fixed | skip (default: auto)
  --desc-template TEMPLATE         Used when mode=template. Supports {name}. Default: "{name}"
  --desc TEXT                      Used when mode=fixed
  --force-description              Overwrite description even if already set

Default safe remote handling:
  - If 'origin' exists and differs from https://github.com/<org>/<repo>.git:
      rename origin -> origin-old (or origin-old-1, ...)
      add new origin -> https://github.com/<org>/<repo>.git
  - Then: add/commit/push

Auth:
  Preferred: gh auth login && gh auth setup-git
  Or: ./$(basename "$0") --token YOUR_TOKEN

Performance:
  Use -j N to process N repositories in parallel (where N is typically 2-8)
  Example: $(basename "$0") -j 4
EOF
}

log() { printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*" >&2; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

make_askpass() {
  local askpass
  askpass="$(mktemp)"
  cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="${1:-}"
case "$prompt" in
  *Username*|*username*) echo "x-access-token" ;;
  *Password*|*password*) echo "${GITHUB_TOKEN:?GITHUB_TOKEN missing}" ;;
  *) echo "" ;;
esac
EOF
  chmod 700 "$askpass"
  echo "$askpass"
}

unique_remote_name() {
  local base="$1"
  local n=0
  local candidate="$base"
  while git remote get-url "$candidate" >/dev/null 2>&1; do
    n=$((n + 1))
    candidate="${base}-${n}"
  done
  echo "$candidate"
}

sanitize_desc() {
  # trim, collapse whitespace, cap length
  python3 - <<'PY' "$1"
import re, sys
s = sys.argv[1]
s = s.replace('\r','').strip()
s = re.sub(r'\s+', ' ', s)
# GitHub UI caps description length (keep it modest)
print(s[:200])
PY
}

infer_description_auto() {
  local name="$1"

  # 1) .git/description (avoid default)
  if [[ -f ".git/description" ]]; then
    local d
    d="$(head -n 1 ".git/description" | tr -d '\r' || true)"
    if [[ -n "$d" && "$d" != "Unnamed repository; edit this file 'description' to name the repository." ]]; then
      sanitize_desc "$d"
      return 0
    fi
  fi

  # 2) README.md (first heading or first non-empty line)
  if [[ -f "README.md" ]]; then
    local line
    # first markdown heading
    line="$(grep -m1 -E '^\s*#\s+' README.md | sed -E 's/^\s*#\s+//' | tr -d '\r' || true)"
    if [[ -z "$line" ]]; then
      # first non-empty line
      line="$(grep -m1 -E '^\s*\S' README.md | tr -d '\r' || true)"
    fi
    if [[ -n "$line" ]]; then
      sanitize_desc "$line"
      return 0
    fi
  fi

  sanitize_desc "Kira.id: ${name}"
}

render_description() {
  local name="$1"
  case "$DESC_MODE" in
    skip) echo "" ;;
    fixed) sanitize_desc "${DESC_FIXED:-Kira.id: ${name}}" ;;
    template)
      sanitize_desc "${DESC_TEMPLATE//\{name\}/$name}"
      ;;
    auto|*)
      infer_description_auto "$name"
      ;;
  esac
}

# Ensure repo exists (create if missing), include description when creating
ensure_github_repo_exists() {
  local org="$1"
  local name="$2"
  local visibility="$3"
  local token="$4"
  local desc="$5"
  local full="${org}/${name}"

  $CREATE_REPOS || return 0

  if have_cmd gh && gh auth status -h github.com >/dev/null 2>&1; then
    if gh repo view "$full" >/dev/null 2>&1; then
      return 0
    fi

    local vis_flag="--public"
    case "$visibility" in
      public) vis_flag="--public" ;;
      private) vis_flag="--private" ;;
      internal) vis_flag="--internal" ;;
      *) vis_flag="--public" ;;
    esac

    if $DRY_RUN; then
      log "  [dry-run] gh repo create $full $vis_flag --description \"$desc\" --confirm"
      return 0
    fi

    if [[ -n "$desc" ]]; then
      gh repo create "$full" "$vis_flag" --description "$desc" --confirm >/dev/null
    else
      gh repo create "$full" "$vis_flag" --confirm >/dev/null
    fi
    return 0
  fi

  if [[ -z "$token" ]]; then
    log "  ERROR: cannot create/check ${full}. Install/authenticate 'gh' or pass --token."
    return 1
  fi

  local api="https://api.github.com"
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    "${api}/repos/${org}/${name}")"

  if [[ "$code" == "200" ]]; then
    return 0
  fi
  if [[ "$code" != "404" ]]; then
    log "  ERROR: GitHub API check failed for ${full} (HTTP $code)."
    return 1
  fi

  # Create repo in org, include description
  local payload
  # Use python to safely JSON-escape the description
  payload="$(python3 - <<'PY' "$name" "$visibility" "$desc"
import json, sys
name, vis, desc = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"name": name}
if vis == "private":
  data["private"] = True
elif vis == "internal":
  data["visibility"] = "internal"
else:
  data["private"] = False
if desc:
  data["description"] = desc
print(json.dumps(data))
PY
)"

  if $DRY_RUN; then
    log "  [dry-run] curl -X POST ${api}/orgs/${org}/repos -d '$payload'"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  local create_code
  create_code="$(curl -sS -o "$tmp" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    "${api}/orgs/${org}/repos" \
    -d "$payload")"

  if [[ "$create_code" == "201" || "$create_code" == "422" ]]; then
    rm -f "$tmp"
    return 0
  fi

  log "  ERROR: failed to create ${full} (HTTP $create_code). Response:"
  sed 's/^/    /' "$tmp" >&2 || true
  rm -f "$tmp"
  return 1
}

get_current_description_api() {
  local org="$1" name="$2" token="$3"
  curl -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${org}/${name}" \
  | python3 - <<'PY'
import json, sys
try:
  data = json.load(sys.stdin)
  d = data.get("description") or ""
  print(d)
except Exception:
  print("")
PY
}

maybe_set_description() {
  local org="$1" name="$2" token="$3" desc="$4"
  local full="${org}/${name}"

  [[ "$DESC_MODE" == "skip" ]] && return 0
  [[ -z "$desc" ]] && return 0

  # Prefer gh
  if have_cmd gh && gh auth status -h github.com >/dev/null 2>&1; then
    local cur
    cur="$(gh repo view "$full" --json description -q .description 2>/dev/null || true)"
    cur="${cur:-}"
    if $FORCE_DESCRIPTION || [[ -z "$cur" ]]; then
      if $DRY_RUN; then
        log "  [dry-run] gh repo edit $full --description \"$desc\""
      else
        gh repo edit "$full" --description "$desc" >/dev/null
      fi
    fi
    return 0
  fi

  # API fallback
  [[ -z "$token" ]] && return 0

  local cur
  cur="$(get_current_description_api "$org" "$name" "$token")"
  if $FORCE_DESCRIPTION || [[ -z "$cur" ]]; then
    local payload
    payload="$(python3 - <<'PY' "$desc"
import json, sys
print(json.dumps({"description": sys.argv[1]}))
PY
)"
    if $DRY_RUN; then
      log "  [dry-run] curl -X PATCH https://api.github.com/repos/${org}/${name} -d '$payload'"
    else
      curl -sS -o /dev/null \
        -X PATCH \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${org}/${name}" \
        -d "$payload" || true
    fi
  fi
}

# Main processing function for a single repository
process_repo() {
  local dir="$1"
  local name="$(basename "$dir")"
  
  log "==> Starting: $name"
  
  if [[ ! -d "$dir/.git" ]]; then
    log "SKIP (no .git): $name"
    return 0
  fi

  (
    cd "$dir"

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "  ERROR: not a git work tree"; exit 10; }

    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    if [[ -z "$branch" ]]; then
      log "  SKIP: detached HEAD"
      exit 0
    fi

    desc="$(render_description "$name")"

    ensure_github_repo_exists "$ORG" "$name" "$VISIBILITY" "$TOKEN" "$desc"
    maybe_set_description "$ORG" "$name" "$TOKEN" "$desc"

    remote_url="https://github.com/${ORG}/${name}.git"

    # SAFEST DEFAULT REMOTE HANDLING
    existing_url=""
    if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
      existing_url="$(git remote get-url "$REMOTE_NAME" || true)"
    fi

    if [[ -n "$existing_url" && "$existing_url" != "$remote_url" ]]; then
      new_old_name="$(unique_remote_name "$OLD_REMOTE_BASE")"
      if $DRY_RUN; then
        log "  [dry-run] git remote rename $REMOTE_NAME $new_old_name"
        log "  [dry-run] git remote add $REMOTE_NAME $remote_url"
      else
        git remote rename "$REMOTE_NAME" "$new_old_name"
        git remote add "$REMOTE_NAME" "$remote_url"
      fi
    elif [[ -z "$existing_url" ]]; then
      if $DRY_RUN; then
        log "  [dry-run] git remote add $REMOTE_NAME $remote_url"
      else
        git remote add "$REMOTE_NAME" "$remote_url"
      fi
    else
      log "  Remote '$REMOTE_NAME' already correct"
    fi

    if $DRY_RUN; then
      log "  [dry-run] git add -A"
    else
      git add -A
    fi

    if $DRY_RUN; then
      if ! git diff --cached --quiet; then
        log "  [dry-run] git commit -m \"$COMMIT_MSG\""
      else
        log "  No staged changes to commit"
      fi
    else
      if ! git diff --cached --quiet; then
        git commit -m "$COMMIT_MSG"
      else
        log "  No staged changes to commit"
      fi
    fi

    push_args=()
    $FORCE && push_args+=(--force-with-lease)

    if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      push_args+=(-u "$REMOTE_NAME" "$branch")
    else
      push_args+=("$REMOTE_NAME" "$branch")
    fi

    if $DRY_RUN; then
      log "  [dry-run] git push ${push_args[*]}"
      exit 0
    fi

    if [[ -n "$TOKEN" ]]; then
      export GITHUB_TOKEN="$TOKEN"
      askpass="$(make_askpass)"
      trap 'rm -f "$askpass"' EXIT
      GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git push "${push_args[@]}"
      rm -f "$askpass"
      trap - EXIT
    else
      git push "${push_args[@]}"
    fi

    log "  Done: $name"
    exit 0
  ) || {
    log "  FAILED: $name"
    return 1
  }
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:?}"; shift 2 ;;
    --org) ORG="${2:?}"; shift 2 ;;
    --visibility) VISIBILITY="${2:?}"; shift 2 ;;
    --message) COMMIT_MSG="${2:?}"; shift 2 ;;
    --token) TOKEN="${2:?}"; shift 2 ;;
    --no-create) CREATE_REPOS=false; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --jobs) PARALLEL_JOBS="${2:?}"; shift 2 ;;
    --desc-mode) DESC_MODE="${2:?}"; shift 2 ;;
    --desc-template) DESC_TEMPLATE="${2:?}"; shift 2 ;;
    --desc) DESC_FIXED="${2:?}"; shift 2 ;;
    --force-description) FORCE_DESCRIPTION=true; shift ;;
    -j) PARALLEL_JOBS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

if [[ ! -d "$REPO_DIR" ]]; then
  log "ERROR: repo-dir '$REPO_DIR' not found."
  exit 1
fi

case "$DESC_MODE" in
  auto|template|fixed|skip) ;;
  *) log "ERROR: invalid --desc-mode '$DESC_MODE'"; exit 2 ;;
esac

log "Repo dir:     $REPO_DIR"
log "Org:          $ORG"
log "Visibility:   $VISIBILITY"
log "Create repos: $CREATE_REPOS"
log "Desc mode:    $DESC_MODE"
log "Parallel jobs: $PARALLEL_JOBS"
log "Dry-run:      $DRY_RUN"
log "Force:        $FORCE"
log ""

# Collect all directories to process
mapfile -t dirs < <(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z | tr '\0' '\n')
total_dirs=${#dirs[@]}

if [[ $total_dirs -eq 0 ]]; then
  log "No directories found in $REPO_DIR"
  exit 0
fi

log "Found $total_dirs directories to process"
log ""

failures=0
processed=0

# Process repositories in parallel or sequentially
if [[ $PARALLEL_JOBS -gt 1 ]]; then
  log "Running with $PARALLEL_JOBS parallel jobs"
  
  # Create a temporary file for results
  results_file="$(mktemp)"
  
  # Export variables needed by process_repo function
  export ORG VISIBILITY TOKEN DESC_MODE DESC_TEMPLATE DESC_FIXED FORCE_DESCRIPTION DRY_RUN FORCE REMOTE_NAME OLD_REMOTE_BASE CREATE_REPOS COMMIT_MSG
  
  # Use GNU parallel if available, otherwise use xargs
  if have_cmd parallel; then
    log "Using GNU parallel"
    # Use GNU parallel for best performance
    printf '%s\n' "${dirs[@]}" | parallel -j "$PARALLEL_JOBS" process_repo {}
    parallel_exit_code=$?
    
    if [[ $parallel_exit_code -ne 0 ]]; then
      log "Warning: parallel processing completed with exit code $parallel_exit_code"
    fi
    
  elif have_cmd xargs; then
    log "Using xargs with -P for parallel processing"
    # Use xargs with -P flag for parallel processing
    printf '%s\n' "${dirs[@]}" | xargs -P "$PARALLEL_JOBS" -I {} bash -c "process_repo '{}'"
    xargs_exit_code=$?
    
    if [[ $xargs_exit_code -ne 0 ]]; then
      log "Warning: xargs processing completed with exit code $xargs_exit_code"
    fi
  else
    log "ERROR: Neither 'parallel' nor 'xargs' found. Cannot run in parallel."
    log "Falling back to sequential processing."
    PARALLEL_JOBS=1
  fi
fi

# Sequential processing (also used as fallback)
if [[ $PARALLEL_JOBS -eq 1 ]]; then
  log "Running sequentially"
  for dir in "${dirs[@]}"; do
    if process_repo "$dir"; then
      processed=$((processed + 1))
    else
      failures=$((failures + 1))
    fi
    log ""
  done
fi

log "Processed: $processed/$total_dirs"
log "Failures:  $failures"
[[ "$failures" -eq 0 ]] || exit 1
