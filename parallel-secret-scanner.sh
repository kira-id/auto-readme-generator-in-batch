#!/bin/bash

# Parallel Secret Scanner - Optimized Batch Processor
# Executes secret-scanner-autofix.sh on git repos under repo/ with parallel processing.

set -euo pipefail
shopt -s nullglob

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_NAME="parallel-secret-scanner.sh"
SCANNER_SCRIPT="./secret-scanner-autofix.sh"
REPO_DIR="repo"
LOG_DIR="parallel-logs"

# Better default for jobs across platforms
default_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc --all
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    echo 4
  fi
}

MAX_PARALLEL_JOBS="$(default_jobs)"

# Runtime variables (allow parent to export and children to reuse)
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
FORCE="${FORCE:-false}"
RESUME="${RESUME:-false}"
PROCESS_SINGLE="${PROCESS_SINGLE:-false}"
SINGLE_REPO="${SINGLE_REPO:-}"

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
START_TS="${START_TS:-$(date +%s)}"

MAIN_LOG_FILE="$LOG_DIR/parallel-scan-$RUN_ID.log"
SUMMARY_FILE="$LOG_DIR/parallel-summary-$RUN_ID.txt"
SUMMARY_TMP="$LOG_DIR/parallel-summary-$RUN_ID.tmp"
REPO_LIST_FILE="$LOG_DIR/repo-list-$RUN_ID.list0"   # NUL-delimited
PROCESSED_FILE="$LOG_DIR/processed-repos.txt"
LOCK_FILE="$LOG_DIR/.parallel-secret-scanner.lock"

# Associative array for tracking processed repositories (parent only)
declare -A PROCESSED_REPOS

mkdir -p "$LOG_DIR"
touch "$MAIN_LOG_FILE"

HAVE_FLOCK=false
if command -v flock >/dev/null 2>&1; then
  HAVE_FLOCK=true
fi

with_lock() {
  # Usage: with_lock command [args...]
  if [ "$HAVE_FLOCK" = true ]; then
    flock -x "$LOCK_FILE" "$@"
  else
    "$@"
  fi
}

log() {
  local level="$1"; shift
  local message="$*"
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"

  # Silence DEBUG unless --verbose
  if [ "$level" = "DEBUG" ] && [ "$VERBOSE" != true ]; then
    return 0
  fi

  case "$level" in
    INFO)  echo -e "${GREEN}[INFO]${NC} [$timestamp] $message" | tee -a "$MAIN_LOG_FILE" >&2 ;;
    WARN)  echo -e "${YELLOW}[WARN]${NC} [$timestamp] $message" | tee -a "$MAIN_LOG_FILE" >&2 ;;
    ERROR) echo -e "${RED}[ERROR]${NC} [$timestamp] $message" | tee -a "$MAIN_LOG_FILE" >&2 ;;
    DEBUG) echo -e "${BLUE}[DEBUG]${NC} [$timestamp] $message" | tee -a "$MAIN_LOG_FILE" >&2 ;;
    *)     echo -e "[UNKNOWN] [$timestamp] $message" | tee -a "$MAIN_LOG_FILE" >&2 ;;
  esac
}

show_help() {
  cat << EOF
Parallel Secret Scanner - Batch Processor
==========================================

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --dry-run      Run in simulation mode (no actual changes)
  --verbose      Enable verbose logging
  --force        Force execution even if dependencies are missing
  --resume       Resume from last checkpoint (skip already processed repos)
  --jobs N       Set maximum parallel jobs (default: system CPU count)
  --help         Show this help message

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dry-run --verbose
  $SCRIPT_NAME --resume
  $SCRIPT_NAME --jobs 8
EOF
}

check_dependencies() {
  log INFO "Checking dependencies..."

  local missing=()

  if [ ! -f "$SCANNER_SCRIPT" ]; then
    log ERROR "Scanner script not found: $SCANNER_SCRIPT"
    missing+=("secret-scanner-autofix.sh")
  elif [ ! -x "$SCANNER_SCRIPT" ]; then
    log ERROR "Scanner script is not executable: $SCANNER_SCRIPT"
    missing+=("executable secret-scanner-autofix.sh")
  fi

  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v find >/dev/null 2>&1 || missing+=("find")
  command -v grep >/dev/null 2>&1 || missing+=("grep")
  command -v awk >/dev/null 2>&1 || missing+=("awk")
  command -v wc >/dev/null 2>&1 || missing+=("wc")
  command -v date >/dev/null 2>&1 || missing+=("date")

  if command -v parallel >/dev/null 2>&1; then
    PARALLEL_TOOL="parallel"
    log INFO "GNU Parallel found"
  elif command -v xargs >/dev/null 2>&1; then
    PARALLEL_TOOL="xargs"
    log INFO "xargs found"
  else
    log ERROR "No parallel processing tool found (GNU Parallel or xargs)"
    missing+=("parallel or xargs")
  fi

  if [ ${#missing[@]} -ne 0 ]; then
    if [ "$FORCE" = true ]; then
      log WARN "Missing tools but continuing due to --force: ${missing[*]}"
    else
      log ERROR "Missing required tools: ${missing[*]}"
      exit 1
    fi
  fi

  log INFO "Dependencies check complete."
}

parse_arguments() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --process-single)
        PROCESS_SINGLE=true
        SINGLE_REPO="${2:-}"
        if [ -z "$SINGLE_REPO" ]; then
          log ERROR "--process-single requires a repository path"
          exit 1
        fi
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --resume)
        RESUME=true
        shift
        ;;
      --jobs)
        if [ -n "${2:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "${2:-}" -gt 0 ]; then
          MAX_PARALLEL_JOBS="$2"
          shift 2
        else
          log ERROR "--jobs requires a positive integer"
          exit 1
        fi
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        log ERROR "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

load_processed_repositories() {
  if [ -f "$PROCESSED_FILE" ]; then
    while IFS= read -r repo; do
      [ -n "$repo" ] && PROCESSED_REPOS["$repo"]=1
    done < "$PROCESSED_FILE"
    log INFO "Loaded ${#PROCESSED_REPOS[@]} already processed repositories"
  else
    PROCESSED_REPOS=()
  fi
}

save_processed_repository() {
  local repo_path="$1"

  # Avoid duplicates under lock
  with_lock bash -c '
    repo="$1"; file="$2"
    touch "$file"
    if ! grep -Fxq -- "$repo" "$file"; then
      printf "%s\n" "$repo" >> "$file"
    fi
  ' bash "$repo_path" "$PROCESSED_FILE"
}

write_summary_line() {
  local line="$1"
  with_lock bash -c '
    line="$1"; file="$2"
    printf "%s\n" "$line" >> "$file"
  ' bash "$line" "$SUMMARY_TMP"
}

find_repositories() {
  log INFO "Finding repositories in $REPO_DIR..."

  if [ ! -d "$REPO_DIR" ]; then
    log WARN "Repo directory not found: $REPO_DIR"
    : > "$REPO_LIST_FILE"
    return 0
  fi

  if [ "$RESUME" = true ]; then
    load_processed_repositories
  fi

  : > "$REPO_LIST_FILE"
  local repo_count=0

  # Top-level directories under repo/
  for dir in "$REPO_DIR"/*; do
    [ -d "$dir" ] || continue

    if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ "$RESUME" = true ] && [ -n "${PROCESSED_REPOS[$dir]:-}" ]; then
        log DEBUG "Skipping already processed: $dir"
        continue
      fi

      printf '%s\0' "$dir" >> "$REPO_LIST_FILE"
      repo_count=$((repo_count + 1))
      log DEBUG "Found repository: $dir"
    else
      log DEBUG "Skipping non-git directory: $dir"
    fi
  done

  log INFO "Found $repo_count valid git repositories to process"
}

process_one_repository() {
  local repo_path="$1"
  local repo_name
  repo_name="$(basename "$repo_path")"
  local safe_repo_name="${repo_name// /_}"
  local repo_log_file="$LOG_DIR/repo-$safe_repo_name-$RUN_ID.log"

  log INFO "Processing repository: $repo_name"
  : > "$repo_log_file"

  local cmd=("$SCANNER_SCRIPT" "$repo_path")
  if [ "$DRY_RUN" = true ]; then
    cmd+=("--dry-run")
  fi

  if "${cmd[@]}" >"$repo_log_file" 2>&1; then
    log INFO "Successfully processed: $repo_name"
    save_processed_repository "$repo_path"

    local gitleaks_count
    local trufflehog_count
    gitleaks_count="$(grep -cF "Gitleaks found" "$repo_log_file" || true)"
    trufflehog_count="$(grep -cF "Trufflehog found" "$repo_log_file" || true)"

    write_summary_line "$repo_path|SUCCESS|$gitleaks_count|$trufflehog_count|$repo_log_file"
    return 0
  else
    log ERROR "Failed to process: $repo_name"
    write_summary_line "$repo_path|FAILED|0|0|$repo_log_file"
    return 1
  fi
}

execute_parallel_scan() {
  # Initialize shared summary tmp
  : > "$SUMMARY_TMP"
  printf "Repository|Status|GitleaksFindings|TrufflehogFindings|LogFile\n" >> "$SUMMARY_TMP"

  # Export runtime vars so workers reuse same run files
  export RUN_ID START_TS LOG_DIR MAIN_LOG_FILE SUMMARY_TMP PROCESSED_FILE LOCK_FILE
  export DRY_RUN VERBOSE FORCE RESUME SCANNER_SCRIPT

  # Flags propagated to workers (must come before --process-single)
  local worker_flags=()
  [ "$DRY_RUN" = true ] && worker_flags+=("--dry-run")
  [ "$VERBOSE" = true ] && worker_flags+=("--verbose")
  [ "$FORCE" = true ] && worker_flags+=("--force")
  [ "$RESUME" = true ] && worker_flags+=("--resume")

  local total_repos
  total_repos="$(tr -cd '\0' < "$REPO_LIST_FILE" | wc -c | awk '{print $1}')"

  if [ "${total_repos:-0}" -eq 0 ]; then
    log WARN "No repositories to process"
    return 0
  fi

  log INFO "Starting parallel processing of $total_repos repositories with max $MAX_PARALLEL_JOBS jobs"

  local rc=0
  set +e
  if [ "$PARALLEL_TOOL" = "parallel" ]; then
    # -0 reads NUL-delimited input safely
    parallel -0 --progress --eta --jobs "$MAX_PARALLEL_JOBS" --line-buffer \
      "$0" "${worker_flags[@]}" --process-single {} :::: "$REPO_LIST_FILE"
    rc=$?
  else
    # xargs -0 reads NUL-delimited input safely
    xargs -0 -P "$MAX_PARALLEL_JOBS" -I {} \
      "$0" "${worker_flags[@]}" --process-single "{}" < "$REPO_LIST_FILE"
    rc=$?
  fi
  set -e

  if [ "$rc" -ne 0 ]; then
    log WARN "Parallel tool returned non-zero exit code: $rc (some repos may have failed)"
  fi

  log INFO "Parallel processing completed"
  return 0
}

generate_summary_report() {
  log INFO "Generating summary report..."
  local end_ts
  end_ts="$(date +%s)"
  local duration=$((end_ts - START_TS))

  local total_repos=0
  local success_count=0
  local failed_count=0
  local total_gitleaks=0
  local total_trufflehog=0
  local success_rate="N/A"

  if [ -f "$SUMMARY_TMP" ]; then
    total_repos="$(tail -n +2 "$SUMMARY_TMP" | wc -l | awk '{print $1}')"
    success_count="$(grep -c "|SUCCESS|" "$SUMMARY_TMP" || true)"
    failed_count="$(grep -c "|FAILED|" "$SUMMARY_TMP" || true)"
    total_gitleaks="$(awk -F'|' '$2=="SUCCESS"{sum+=$3} END{print sum+0}' "$SUMMARY_TMP")"
    total_trufflehog="$(awk -F'|' '$2=="SUCCESS"{sum+=$4} END{print sum+0}' "$SUMMARY_TMP")"
    success_rate="$(awk -v s="$success_count" -v t="$total_repos" 'BEGIN{ if(t==0) print "N/A"; else printf "%.2f", (s*100)/t }')"
  fi

  cat > "$SUMMARY_FILE" << EOF
Parallel Secret Scanner - Summary Report
========================================

Execution Information:
--------------------
Start Time: $(date -d "@$START_TS" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date +'%Y-%m-%d %H:%M:%S')
End Time:   $(date -d "@$end_ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date +'%Y-%m-%d %H:%M:%S')
Duration:   ${duration}s
Run ID:     $RUN_ID
Mode:       $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")
Jobs:       $MAX_PARALLEL_JOBS

Processing Results:
------------------
Total Repositories: $total_repos
Successful:         $success_count
Failed:             $failed_count
Success Rate:       ${success_rate}%

Scan Findings:
-------------
Total Gitleaks Findings:    $total_gitleaks
Total Trufflehog Findings:  $total_trufflehog
Total Findings:             $((total_gitleaks + total_trufflehog))

Repository Details:
------------------
EOF

  if [ -f "$SUMMARY_TMP" ]; then
    tail -n +2 "$SUMMARY_TMP" >> "$SUMMARY_FILE"
  fi

  cat >> "$SUMMARY_FILE" << EOF

Log Files:
---------
Main Log:            $MAIN_LOG_FILE
Summary Report:      $SUMMARY_FILE
Repo Logs Directory: $LOG_DIR

Notes:
-----
- Review failed repositories for specific errors
- Check individual repo log files for detailed scan results
- Rotate any exposed credentials immediately
EOF

  log INFO "Summary report generated: $SUMMARY_FILE"

  echo ""
  echo "========================================"
  echo "Parallel Secret Scanner - Execution Complete"
  echo "========================================"
  echo "Total Repositories: $total_repos"
  echo "Successful: $success_count"
  echo "Failed: $failed_count"
  echo "Total Findings: $((total_gitleaks + total_trufflehog))"
  echo "Duration: ${duration}s"
  echo ""
  echo "Full report: $SUMMARY_FILE"
  echo "Main log: $MAIN_LOG_FILE"
}

cleanup() {
  # Keep logs for debugging
  true
}

main() {
  parse_arguments "$@"

  if [ "$PROCESS_SINGLE" = true ]; then
    process_one_repository "$SINGLE_REPO"
    exit $?
  fi

  log INFO "Starting Parallel Secret Scanner"
  log INFO "Run ID: $RUN_ID"
  log INFO "Main log: $MAIN_LOG_FILE"

  check_dependencies
  find_repositories

  if [ ! -s "$REPO_LIST_FILE" ]; then
    log WARN "No repositories found to process"
    generate_summary_report
    return 0
  fi

  execute_parallel_scan
  generate_summary_report

  log INFO "Parallel Secret Scanner completed"
}

trap cleanup EXIT
trap 'log ERROR "Script interrupted"; exit 130' INT
trap 'log ERROR "Script terminated"; exit 143' TERM

main "$@"
