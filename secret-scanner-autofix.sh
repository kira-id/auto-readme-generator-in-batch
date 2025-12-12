#!/bin/bash

# Secret Scanner and Autofix Script
# Combines gitleaks and trufflehog scanning with optional git history cleaning
# Usage: ./secret-scanner-autofix.sh <folder_path> [--dry-run] [--no-history] [--flatten]

set -euo pipefail
umask 077

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ORIGINAL_WD="$(pwd)"

# Run-scoped IDs and paths
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

# Store logs and artifacts outside the repo to avoid accidental commits
LOG_ROOT="${TMPDIR:-/tmp}/secret-scanner"
LOG_DIR="$LOG_ROOT/$RUN_ID"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/secret-scanner.log"
: > "$LOG_FILE" || { echo "Cannot write log file: $LOG_FILE"; exit 1; }
chmod 600 "$LOG_FILE" 2>/dev/null || true

GITLEAKS_REPORT="$LOG_DIR/gitleaks-report.json"
TRUFFLEHOG_REPORT="$LOG_DIR/trufflehog-report.jsonl"
REPLACEMENTS_FILE="$LOG_DIR/replacements.txt"

DRY_RUN=false
NO_HISTORY=false
FLATTEN=false

log() {
    local level="$1"
    shift
    local message="$*"

    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" | tee -a "$LOG_FILE" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" | tee -a "$LOG_FILE" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE" ;;
        DEBUG) echo -e "${BLUE}[DEBUG]${NC} $message" | tee -a "$LOG_FILE" ;;
        *)     echo -e "[UNKNOWN] $message" | tee -a "$LOG_FILE" ;;
    esac
}

# Resolve absolute path robustly
resolve_repo_path() {
    local repo_path="$1"
    if [[ "$repo_path" == /* ]]; then
        echo "$repo_path"
    else
        echo "$ORIGINAL_WD/$repo_path"
    fi
}

# Check if a command exists
has_cmd() {
    command -v "$1" &>/dev/null
}

# Portable sed -i wrapper (GNU sed vs BSD/macOS sed)
sedi() {
    local expr="$1"
    shift
    if sed --version >/dev/null 2>&1; then
        sed -i "$expr" "$@"
    else
        sed -i '' "$expr" "$@"
    fi
}

# Run git-filter-repo whichever form exists
run_filter_repo() {
    if git filter-repo --help &>/dev/null; then
        git filter-repo "$@"
    elif has_cmd git-filter-repo; then
        git-filter-repo "$@"
    else
        return 127
    fi
}

show_help() {
    cat << EOF
Secret Scanner and Autofix Script

Usage: $0 <folder_path> [--dry-run] [--no-history] [--flatten]

Arguments:
    folder_path    Path to the git repository to scan and clean
    --dry-run      Run in simulation mode (no actual changes to git history)
    --no-history   Only scan current files, skip git history scanning/rewriting
    --flatten      Flatten git history into a single commit after cleaning

Description:
    Combines gitleaks and trufflehog for secret detection.
    If --no-history is not set, it can rewrite history using git-filter-repo.

Requirements:
    - gitleaks
    - trufflehog
    - git
    - jq
    - git-filter-repo (only required if NOT using --no-history)

Artifacts:
    Logs and temporary artifacts are stored in: $LOG_DIR

Examples:
    $0 /path/to/repo
    $0 /path/to/repo --dry-run
    $0 /path/to/repo --no-history
    $0 /path/to/repo --flatten
EOF
}

validate_input() {
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi

    local folder_path="$1"

    if [[ "$folder_path" == --* ]]; then
        log ERROR "Missing folder_path. First argument must be a folder path."
        show_help
        exit 1
    fi

    shift || true

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                log INFO "Running in DRY-RUN mode"
                shift
                ;;
            --no-history)
                NO_HISTORY=true
                log INFO "NO-HISTORY mode enabled"
                shift
                ;;
            --flatten)
                FLATTEN=true
                log INFO "FLATTEN mode enabled"
                shift
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    local abs_repo_path
    abs_repo_path=$(resolve_repo_path "$folder_path")

    if [ ! -d "$abs_repo_path" ]; then
        log ERROR "Folder does not exist: $abs_repo_path"
        exit 1
    fi

    if ! git -C "$abs_repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
        log ERROR "Not a git repository: $abs_repo_path"
        exit 1
    fi
}

check_dependencies() {
    log INFO "Checking dependencies..."

    local missing=()

    has_cmd gitleaks || missing+=("gitleaks")
    has_cmd trufflehog || missing+=("trufflehog")
    has_cmd git || missing+=("git")
    has_cmd jq || missing+=("jq")

    # Only require filter-repo if we might rewrite history
    if [ "$NO_HISTORY" = false ]; then
        if ! (git filter-repo --help &>/dev/null || has_cmd git-filter-repo); then
            missing+=("git-filter-repo")
        fi
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log ERROR "Missing required tools: ${missing[*]}"
        exit 1
    fi

    log INFO "All required dependencies are available for the selected mode."
}

count_gitleaks_findings() {
    if [ -f "$GITLEAKS_REPORT" ] && [ -s "$GITLEAKS_REPORT" ]; then
        jq 'length' "$GITLEAKS_REPORT" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

count_trufflehog_findings() {
    if [ -f "$TRUFFLEHOG_REPORT" ] && [ -s "$TRUFFLEHOG_REPORT" ]; then
        jq -s 'length' "$TRUFFLEHOG_REPORT" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

scan_with_gitleaks() {
    local repo_path="$1"
    local abs_repo_path
    abs_repo_path=$(resolve_repo_path "$repo_path")

    log INFO "Running gitleaks scan on $abs_repo_path"

    local args=(detect --source "." --report-format=json --report-path="$GITLEAKS_REPORT")

    if [ "$NO_HISTORY" = true ]; then
        args+=(--no-git)
        log INFO "Gitleaks NO-HISTORY mode: scanning working tree only"
    else
        log INFO "Gitleaks default mode: scanning repository"
    fi

    # Do not print scanner output to terminal (can leak secrets). Save to log file only.
    if (cd "$abs_repo_path" && gitleaks "${args[@]}" --verbose) >>"$LOG_FILE" 2>&1; then
        log INFO "Gitleaks scan completed"
    else
        log WARN "Gitleaks returned non-zero (findings or error). See log file."
    fi

    local findings
    findings="$(count_gitleaks_findings)"
    if [ "$findings" -gt 0 ]; then
        log INFO "Gitleaks found $findings potential secrets"
        return 0
    fi

    log INFO "No secrets found by gitleaks"
    return 1
}

scan_with_trufflehog() {
    local repo_path="$1"
    local abs_repo_path
    abs_repo_path=$(resolve_repo_path "$repo_path")

    log INFO "Running trufflehog scan on $abs_repo_path"

    # Do not print scanner output to terminal (can leak secrets). Save to log file only.
    if [ "$NO_HISTORY" = true ]; then
        log INFO "Trufflehog NO-HISTORY mode: filesystem scan"
        if trufflehog filesystem "$abs_repo_path" --results=verified,unknown --json > "$TRUFFLEHOG_REPORT" 2>>"$LOG_FILE"; then
            log INFO "Trufflehog scan completed"
        else
            log WARN "Trufflehog returned non-zero (findings or error). See log file."
        fi
    else
        log INFO "Trufflehog default mode: git scan with history"
        if trufflehog git "file://$abs_repo_path" --results=verified,unknown --json > "$TRUFFLEHOG_REPORT" 2>>"$LOG_FILE"; then
            log INFO "Trufflehog scan completed"
        else
            log WARN "Trufflehog returned non-zero (findings or error). See log file."
        fi
    fi

    local findings
    findings="$(count_trufflehog_findings)"
    if [ "$findings" -gt 0 ]; then
        log INFO "Trufflehog found $findings potential secrets"
        return 0
    fi

    log INFO "No secrets found by trufflehog"
    return 1
}

create_replacement_patterns() {
    log INFO "Creating replacement patterns..."
    : > "$REPLACEMENTS_FILE"
    chmod 600 "$REPLACEMENTS_FILE" 2>/dev/null || true

    local tmp_file
    tmp_file="$(mktemp)"
    : > "$tmp_file"

    # Extract secrets from gitleaks
    if [ -f "$GITLEAKS_REPORT" ] && [ -s "$GITLEAKS_REPORT" ]; then
        log INFO "Processing gitleaks results..."
        jq -r '.[] | .Secret // empty' "$GITLEAKS_REPORT" 2>/dev/null >> "$tmp_file" || true
    fi

    # Extract secrets from trufflehog JSONL
    if [ -f "$TRUFFLEHOG_REPORT" ] && [ -s "$TRUFFLEHOG_REPORT" ]; then
        log INFO "Processing trufflehog results..."
        # Try a couple of common fields across versions
        jq -r '(.Raw // .RawV2 // empty)' "$TRUFFLEHOG_REPORT" 2>/dev/null >> "$tmp_file" || true
    fi

    local idx=0
    if [ -s "$tmp_file" ]; then
        while IFS= read -r secret; do
            secret="${secret//$'\r'/}"
            [ -z "$secret" ] && continue

            # Guard: lines containing the delimiter will break parsing later
            if [[ "$secret" == *"==>"* ]]; then
                continue
            fi

            local replacement="REDACTED_SECRET_$idx"
            echo "$secret==>$replacement" >> "$REPLACEMENTS_FILE"
            idx=$((idx + 1))
        done < <(grep -v '^[[:space:]]*$' "$tmp_file" | sort -u)
    fi

    rm -f "$tmp_file"

    log INFO "Created $idx replacement patterns (stored in a sensitive file)"
    if [ "$idx" -eq 0 ]; then
        log WARN "No specific secret values extracted. History rewrite would be ineffective."
    fi
}

flatten_git_history() {
    log INFO "Flattening repository history to single commit..."

    if $DRY_RUN; then
        log INFO "DRY-RUN: Would flatten git history"
        return 0
    fi

    local current_branch
    current_branch="$(git branch --show-current || true)"
    [ -z "$current_branch" ] && current_branch="main"

    local temp_branch="temp-flatten-$(date +%s)-$$"

    git checkout --orphan "$temp_branch"
    git rm -rf . >/dev/null 2>&1 || true

    git add -A

    # Avoid failing if there is nothing to commit
    if git diff --cached --quiet; then
        log WARN "Nothing to commit after flatten operation. Skipping commit."
    else
        git commit -m "Flattened repository after secret cleanup ($(date +%Y-%m-%d))"
    fi

    if git show-ref --verify --quiet "refs/heads/$current_branch"; then
        git branch -D "$current_branch"
    fi

    git branch -m "$current_branch"
    log INFO "Repository history flattened to single commit on $current_branch"
}

clean_git_history() {
    local repo_path="$1"
    local abs_repo_path
    abs_repo_path=$(resolve_repo_path "$repo_path")

    log INFO "Cleaning git history..."

    if $DRY_RUN; then
        log INFO "DRY-RUN: Would run git-filter-repo with replacements (not printing secrets)"
        log INFO "Replacements file path: $REPLACEMENTS_FILE"
        log INFO "Replacement lines: $(wc -l < "$REPLACEMENTS_FILE" 2>/dev/null || echo 0)"
        return 0
    fi

    if [ ! -s "$REPLACEMENTS_FILE" ]; then
        log ERROR "Replacements file is empty. Refusing to rewrite history."
        return 1
    fi

    log WARN "Backup is DISABLED as requested. History rewrite is destructive and hard to undo."
    log WARN "Proceed only if you are sure you can recover from a remote or other copy."

    (cd "$abs_repo_path" && run_filter_repo --replace-text "$REPLACEMENTS_FILE" --force) >>"$LOG_FILE" 2>&1 || {
        log ERROR "Failed to clean git history. See log file."
        return 1
    }

    log INFO "Git history cleaned successfully"

    if [ "$FLATTEN" = true ]; then
        (cd "$abs_repo_path" && flatten_git_history) >>"$LOG_FILE" 2>&1 || {
            log ERROR "Flatten step failed. See log file."
            return 1
        }
    fi

    # Note: git-filter-repo may remove origin remote automatically
    if git -C "$abs_repo_path" remote get-url origin &>/dev/null; then
        log WARN "Remote origin detected. You will likely need:"
        log WARN "  git push --force origin --all"
        log WARN "  git push --force origin --tags"
    fi
}

replace_current_files_only() {
    local repo_path="$1"
    local abs_repo_path
    abs_repo_path=$(resolve_repo_path "$repo_path")

    log INFO "Replacing secrets in current files only..."

    if [ ! -s "$REPLACEMENTS_FILE" ]; then
        log ERROR "Replacements file not found or empty: $REPLACEMENTS_FILE"
        return 1
    fi

    (cd "$abs_repo_path" && {
        local replacements_count=0

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [[ "$line" != *"==>"* ]] && continue

            local secret="${line%%==>*}"
            local replacement="${line#*==>}"

            [ -z "$secret" ] && continue
            [ -z "$replacement" ] && continue

            local files
            files="$(git grep -Il --fixed-strings -- "$secret" || true)"
            [ -z "$files" ] && continue

            # Escape for sed BRE pattern (treat secret literally as much as possible)
            # Pattern: escape backslash first, then regex metacharacters, then delimiter.
            local esc_secret esc_repl
            esc_secret="$(printf '%s' "$secret" | sed -e 's/\\/\\\\/g' -e 's/[.[\^$*]/\\&/g' -e 's/[]]/\\&/g' -e 's/[|\/&]/\\&/g')"
            # Replacement: escape backslash, ampersand, delimiter
            esc_repl="$(printf '%s' "$replacement" | sed -e 's/\\/\\\\/g' -e 's/[|\/&]/\\&/g')"

            local file_count
            file_count="$(printf '%s\n' "$files" | wc -l | tr -d '[:space:]')"

            while IFS= read -r f; do
                [ -z "$f" ] && continue
                sedi "s|$esc_secret|$esc_repl|g" "$f" >/dev/null 2>&1 || true
            done <<< "$files"

            replacements_count=$((replacements_count + 1))
            log DEBUG "Applied 1 replacement pattern to $file_count file(s)"
        done < "$REPLACEMENTS_FILE"

        log INFO "Secrets replacement passes completed ($replacements_count patterns)"

        if [ "$DRY_RUN" = false ]; then
            # Only commit if there are changes
            if git status --porcelain | grep -q .; then
                log INFO "Staging changes..."
                git add -A

                if git diff --cached --quiet; then
                    log INFO "No staged changes to commit."
                else
                    log INFO "Committing changes..."
                    if git commit -m "Automatically redacted secrets from current files" >>"$LOG_FILE" 2>&1; then
                        log INFO "Changes committed successfully."
                    else
                        log WARN "Commit failed (possibly missing user.name/email). Changes are staged."
                    fi
                fi
            else
                log INFO "No file changes detected after replacements. Skipping commit."
            fi
        else
            log INFO "DRY-RUN: Would stage and commit changes."
        fi
    })
}

cleanup() {
    # Return to original working directory
    cd "$ORIGINAL_WD" >/dev/null 2>&1 || true

    # Idempotent cleanup
    rm -f "$GITLEAKS_REPORT" "$TRUFFLEHOG_REPORT" 2>/dev/null || true
    # Note: REPLACEMENTS_FILE can contain secrets; delete it manually when done if you do not need it.
}

generate_summary() {
    local repo_path="$1"
    local summary_file="$LOG_DIR/scan-summary.txt"

    local mode_desc="Default (full history scan and clean)"
    if [ "$NO_HISTORY" = true ]; then
        mode_desc="Current files only (NO-HISTORY mode)"
    elif [ "$FLATTEN" = true ]; then
        mode_desc="Full scan with history flattening (FLATTEN mode)"
    fi

    local gl_count th_count
    gl_count="$(count_gitleaks_findings)"
    th_count="$(count_trufflehog_findings)"

    cat > "$summary_file" << EOF
Secret Scanner and Autofix Summary Report
========================================

Repository: $repo_path
Scan Date: $(date)
Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")
Scanning Mode: $mode_desc

Scan Results:
-------------
Gitleaks Findings: $gl_count
Trufflehog Findings: $th_count

Replacement Patterns Created: $( [ -f "$REPLACEMENTS_FILE" ] && wc -l < "$REPLACEMENTS_FILE" || echo "0" )

Actions Taken:
--------------
$(if [ "$DRY_RUN" = true ]; then
    echo "- DRY-RUN mode (no changes made)"
else
    if [ "$NO_HISTORY" = true ]; then
        echo "- Replaced secrets in current tracked files"
    else
        echo "- Rewrote history with git-filter-repo (backup disabled by request)"
        [ "$FLATTEN" = true ] && echo "- Flattened history to a single commit"
    fi
fi)

Next Steps:
-----------
- Rotate any exposed credentials immediately
- Review reports for false positives
- Add pre-commit secret scanning (gitleaks or trufflehog)
- If you rewrote history, force-push all branches and tags (and coordinate with collaborators)

Artifacts Directory: $LOG_DIR
Log File: $LOG_FILE
Summary File: $summary_file
EOF

    log INFO "Summary report generated: $summary_file"
}

main() {
    local repo_path="${1:-}"

    # Parse flags first so dependency checks can be mode-aware
    validate_input "$@"

    log INFO "Starting secret scanner and autofix process..."
    log INFO "Repository: $repo_path"
    log INFO "Artifacts: $LOG_DIR"
    log INFO "Log file: $LOG_FILE"

    check_dependencies

    local gitleaks_found=false
    local trufflehog_found=false

    if scan_with_gitleaks "$repo_path"; then
        gitleaks_found=true
    fi

    if scan_with_trufflehog "$repo_path"; then
        trufflehog_found=true
    fi

    create_replacement_patterns

    if [ "$gitleaks_found" = false ] && [ "$trufflehog_found" = false ]; then
        log INFO "No secrets found by either scanner. Exiting."
        generate_summary "$repo_path"
        return 0
    fi

    if [ "$NO_HISTORY" = true ]; then
        log INFO "NO-HISTORY mode: skipping git history cleaning"

        if $DRY_RUN; then
            log INFO "DRY-RUN: Would replace secrets in current files (not printing secrets)"
            log INFO "Replacements file path: $REPLACEMENTS_FILE"
            log INFO "Replacement lines: $(wc -l < "$REPLACEMENTS_FILE" 2>/dev/null || echo 0)"
        else
            replace_current_files_only "$repo_path"
        fi
    else
        clean_git_history "$repo_path"
    fi

    generate_summary "$repo_path"
    log INFO "Secret scanner and autofix process completed!"
}

trap cleanup EXIT
trap 'log ERROR "Script interrupted"; exit 130' INT
trap 'log ERROR "Script terminated"; exit 143' TERM

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
    exit 0
fi

main "$@"
