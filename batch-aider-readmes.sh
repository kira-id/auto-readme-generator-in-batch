#!/usr/bin/env bash
set -euo pipefail

MODEL_DEFAULT="mistralai/devstral-2512:free"

JOBS_DEFAULT="$(
  getconf _NPROCESSORS_ONLN 2>/dev/null \
  || nproc 2>/dev/null \
  || echo 4
)"

TIMEOUT_DEFAULT=300
RETRY_DEFAULT=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --api-key <OPENROUTER_KEY> [--model <MODEL_NAME>] [--repo <PATH>] [--jobs N] [--timeout N] [--retry N] [--dry-run] [--force]

Options:
  --api-key   Required. OpenRouter API key.
  --model     Optional. Default: ${MODEL_DEFAULT}
  --repo      Optional. Default: ./repo (relative to current dir) or ./repo next to this script if found
  --jobs      Optional. Parallel workers. Default: ${JOBS_DEFAULT}
  --timeout   Optional. Timeout per repository in seconds. Default: ${TIMEOUT_DEFAULT} (5 minutes)
  --retry     Optional. Number of retry attempts for failed repos. Default: ${RETRY_DEFAULT} (no retries)
  --dry-run   Optional. Print actions only, do not modify files and do not update checkpoint.
  --force     Optional. Re-run aider even if checkpoint says aider_ok.
  -h, --help  Show help.
EOF
}

API_KEY=""
MODEL_IN="$MODEL_DEFAULT"
DRY_RUN=0
FORCE=0
JOBS="$JOBS_DEFAULT"
TIMEOUT="$TIMEOUT_DEFAULT"
RETRY="$RETRY_DEFAULT"

# Prefer a "repo" folder next to this script if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$PWD/repo"
if [[ -d "$SCRIPT_DIR/repo" ]]; then
  REPO_DIR="$SCRIPT_DIR/repo"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --model) MODEL_IN="${2:-}"; shift 2 ;;
    --repo) REPO_DIR="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --retry) RETRY="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$API_KEY" ]]; then
  echo "Error: --api-key is required." >&2
  exit 2
fi

# Validate jobs
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
  echo "Warning: invalid --jobs '$JOBS', using default '$JOBS_DEFAULT'." >&2
  JOBS="$JOBS_DEFAULT"
fi

# Validate timeout
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -lt 1 ]]; then
  echo "Warning: invalid --timeout '$TIMEOUT', using default '$TIMEOUT_DEFAULT'." >&2
  TIMEOUT="$TIMEOUT_DEFAULT"
fi

# Validate retry
if ! [[ "$RETRY" =~ ^[0-9]+$ ]] || [[ "$RETRY" -lt 0 ]]; then
  echo "Warning: invalid --retry '$RETRY', using default '$RETRY_DEFAULT'." >&2
  RETRY="$RETRY_DEFAULT"
fi

# Resolve repo dir to absolute path (this fixes the double-cd issue)
if [[ ! -d "$REPO_DIR" ]]; then
  echo "Error: repo dir not found: $REPO_DIR" >&2
  exit 1
fi
REPO_DIR="$(cd "$REPO_DIR" && pwd -P)"

command -v aider >/dev/null 2>&1 || { echo "Error: aider not found in PATH." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found in PATH." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "Error: flock not found in PATH." >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Error: sha256sum not found in PATH." >&2; exit 1; }
command -v mktemp >/dev/null 2>&1 || { echo "Error: mktemp not found in PATH." >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "Error: timeout not found in PATH." >&2; exit 1; }

MODEL="$MODEL_IN"
if [[ "$MODEL" != openrouter/* ]]; then
  MODEL="openrouter/$MODEL"
fi

STATE_DIR="$REPO_DIR/.aider-batch"
STATE_FILE="$STATE_DIR/state.tsv"
LOCK_FILE="$STATE_DIR/state.lock"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$STATE_DIR/logs/$RUN_ID"
RESULTS_DIR="$STATE_DIR/results/$RUN_ID"
TMP_DIR="$STATE_DIR/tmp/$RUN_ID"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$RESULTS_DIR" "$TMP_DIR"
touch "$STATE_FILE" "$LOCK_FILE"

export GIT_TERMINAL_PROMPT=0

state_append() {
  # folder<TAB>status<TAB>utc_iso<TAB>duration_s<TAB>exit_code<TAB>model<TAB>note
  local folder="$1" status="$2" utc_iso="$3" duration_s="$4" exit_code="$5" model="$6" note="${7:-}"
  flock -x "$LOCK_FILE" bash -c 'printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$8"' \
    _ "$folder" "$status" "$utc_iso" "$duration_s" "$exit_code" "$model" "$note" "$STATE_FILE"
}

state_last_status() {
  local folder="$1"
  flock -x "$LOCK_FILE" awk -F'\t' -v r="$folder" '$1==r{last=$2} END{print last}' "$STATE_FILE"
}

track_failed_repo() {
  local folder="$1"
  local failed_file="$STATE_DIR/failed_repos.tmp"
  echo "$folder" >> "$failed_file"
}

get_failed_repos() {
  local failed_file="$STATE_DIR/failed_repos.tmp"
  if [[ -f "$failed_file" ]]; then
    cat "$failed_file"
  fi
}

clear_failed_repos() {
  local failed_file="$STATE_DIR/failed_repos.tmp"
  [[ -f "$failed_file" ]] && rm -f "$failed_file"
}

ensure_gitignore_has_aider() {
  [[ -f .gitignore ]] || : > .gitignore
  if ! grep -Eq '^[[:space:]]*\.aider\*[[:space:]]*$' .gitignore; then
    if [[ -s .gitignore ]]; then
      # ensure newline at EOF
      tail -c 1 .gitignore | grep -q $'\n' || echo >> .gitignore
    fi
    printf ".aider*\n" >> .gitignore
  fi
}

write_apache_license() {
  cat > LICENSE <<'EOF'
Copyright 2025 Samuel Koesnadi (samuel@kira.id)

                                  Apache License
                            Version 2.0, January 2004
                         http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

   END OF TERMS AND CONDITIONS
EOF
}

write_git_description() {
  local repo_name="$1"
  local git_dir=".git"
  local desc_file="$git_dir/description"
  [[ -d "$git_dir" ]] || return 0
  if [[ ! -f "$desc_file" ]]; then
    printf "%s\n" "$repo_name" > "$desc_file" || true
  else
    if grep -qi '^Unnamed repository' "$desc_file" 2>/dev/null; then
      printf "%s\n" "$repo_name" > "$desc_file" || true
    fi
  fi
}

sha_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo ""
  fi
}

find_pruned() {
  # Usage: find_pruned <find-args...>
  # Prunes common large/irrelevant directories for context discovery.
  find . \
    \( \
      -path './.git' -o -path './.git/*' -o \
      -path './node_modules' -o -path './node_modules/*' -o \
      -path './.next' -o -path './.next/*' -o \
      -path './dist' -o -path './dist/*' -o \
      -path './build' -o -path './build/*' -o \
      -path './out' -o -path './out/*' -o \
      -path './coverage' -o -path './coverage/*' -o \
      -path './.turbo' -o -path './.turbo/*' -o \
      -path './.cache' -o -path './.cache/*' -o \
      -path './target' -o -path './target/*' -o \
      -path './vendor' -o -path './vendor/*' -o \
      -path './.venv' -o -path './.venv/*' -o \
      -path './venv' -o -path './venv/*' -o \
      -path './__pycache__' -o -path './__pycache__/*' \
    \) -prune -o \
    "$@"
}

collect_context_files() {
  # Prints 1+ context files (relative paths), preferring high-signal configs and a few representative sources.
  local max_files="${1:-8}"
  local -a selected=()
  declare -A seen=()

  add_file() {
    local f="$1"
    [[ -n "$f" ]] || return 0
    f="${f#./}"
    [[ -n "$f" ]] || return 0
    [[ -f "$f" ]] || return 0
    if [[ -z "${seen["$f"]+x}" ]]; then
      seen["$f"]=1
      selected+=("$f")
    fi
  }

  local f

  # High-signal files (common across JS/Next/Node, plus general repo context).
  local -a important_exact=(
    package.json pnpm-workspace.yaml pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json
    next.config.js next.config.mjs next.config.ts
    tsconfig.json tsconfig.base.json jsconfig.json
    vite.config.ts vite.config.js vite.config.mjs
    webpack.config.js webpack.config.ts webpack.config.mjs
    rollup.config.js rollup.config.ts rollup.config.mjs
    svelte.config.js nuxt.config.js nuxt.config.ts astro.config.mjs remix.config.js
    eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json
    .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js prettier.config.js
    babel.config.js .babelrc .babelrc.json
    postcss.config.js tailwind.config.js tailwind.config.ts
    vercel.json netlify.toml firebase.json
    Dockerfile docker-compose.yml docker-compose.yaml compose.yml Makefile
    pyproject.toml requirements.txt setup.py setup.cfg poetry.lock
    Cargo.toml go.mod pom.xml build.gradle settings.gradle
  )

  for name in "${important_exact[@]}"; do
    f="$(find_pruned -type f -name "$name" -print 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
    [[ -n "$f" ]] && add_file "$f"
    [[ "${#selected[@]}" -ge "$max_files" ]] && break
  done

  # Representative source files (helpful for accurate README claims), especially for JS/Next.
  if [[ "${#selected[@]}" -lt "$max_files" ]]; then
    while IFS= read -r f; do
      add_file "$f"
      [[ "${#selected[@]}" -ge "$max_files" ]] && break
    done < <(
      find_pruned -type f \
        \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) \
        -print 2>/dev/null \
        | grep -E '^\./(src|app|pages|server|lib|packages|apps)/' \
        | LC_ALL=C sort \
        | head -n 4
    )
  fi

  # Add a couple of "random but plausible" extra files for weird repos / uncommon layouts.
  # Ensure we always include at least 1 context file, ideally >=3.
  local want_random=2
  if [[ "${#selected[@]}" -lt 3 ]]; then
    want_random="$((3 - ${#selected[@]}))"
  fi
  if [[ "$want_random" -gt 0 && "${#selected[@]}" -lt "$max_files" ]]; then
    local -a candidates=()
    mapfile -t candidates < <(
      find_pruned -type f -size -200k \
        ! -name '*.png' ! -name '*.jpg' ! -name '*.jpeg' ! -name '*.gif' ! -name '*.webp' ! -name '*.svg' \
        ! -name '*.pdf' ! -name '*.zip' ! -name '*.tar' ! -name '*.gz' ! -name '*.7z' ! -name '*.jar' \
        ! -name '*.bin' ! -name '*.exe' ! -name '*.dll' ! -name '*.so' ! -name '*.dylib' \
        -print 2>/dev/null \
        | sed 's|^\./||' \
        | LC_ALL=C sort
    )

    if [[ "${#candidates[@]}" -gt 0 ]]; then
      if command -v shuf >/dev/null 2>&1; then
        while IFS= read -r f; do
          add_file "$f"
          [[ "${#selected[@]}" -ge "$max_files" ]] && break
        done < <(printf '%s\n' "${candidates[@]}" | shuf -n "$want_random" 2>/dev/null || true)
      else
        local i=0
        while [[ $i -lt "$want_random" && $i -lt "${#candidates[@]}" ]]; do
          add_file "${candidates[$i]}"
          i=$((i + 1))
        done
      fi
    fi
  fi

  # Absolute fallback: pick any file (even README) so we always provide at least one --read.
  if [[ "${#selected[@]}" -eq 0 ]]; then
    f="$(find_pruned -type f -print 2>/dev/null | head -n 1 || true)"
    [[ -n "$f" ]] && add_file "$f"
  fi

  printf '%s\n' "${selected[@]}"
}

build_message_file() {
  local repo_name="$1"
  local msg_file="$2"

  {
    if [[ -f .git/description ]]; then
      printf '%s\n\n' "Rewrite README.md using EDIT FORMAT DIFF and update .git/description."
    else
      printf '%s\n\n' "Rewrite README.md using EDIT FORMAT DIFF."
    fi
    printf '%s\n' "Hard rules:"
    printf '%s\n' "- Edit README.md."
    if [[ -f .git/description ]]; then
      printf '%s\n' "- Edit .git/description."
    else
      printf '%s\n' "- Do not create a new .git directory."
    fi
    printf '%s\n' "- Keep claims strictly accurate to files in this folder. Do not invent features."
    printf '%s\n' "- Produce a useful end-user README with these sections: why this repo, background on what situation this solution fits, use cases, quick start, detailed installation and usage, development progress, what this repository not yet solved, contributing."
    printf '%s\n' "- Include a License section: Apache-2.0 and a LICENSE file exists."
    printf '%s\n' "- Use the existing README.md as context, but do not keep generic placeholders if code reveals concrete behavior."
    printf '%s\n' "- Do NOT create any new files. Do NOT interpret command examples (like 'python3 script.py') as file creation commands."
    printf '%s\n' "- Command examples in markdown code blocks are documentation, not instructions to create files."
    printf '%s\n' "- Repository content must be engaging, clear, and descriptive."
    printf '%s\n' "- The first line should be a descriptive title (not '# repo-folder-name'). Create a compelling, descriptive title that reflects the repository'\''s purpose."
    printf '%s\n' "- Do NOT start with an 'Overview' heading - go straight to content."
    if [[ -f .git/description ]]; then
      printf '%s\n' "- Write a concise, descriptive summary for .git/description that captures the essence of this repository."
    fi
    printf 'Repository: %s\n\n' "$repo_name"
    printf '%s\n' "Original README.md (context):"
    printf '%s\n' '```markdown'
    if [[ -f README.md ]]; then
      cat README.md
    fi
    printf '\n%s\n' '```'
    if [[ -f .git/description ]]; then
      printf '\n%s\n' "Current .git/description (context):"
      printf '%s\n' '```text'
      cat .git/description || true
      printf '\n%s\n' '```'
    fi
  } > "$msg_file"
}

run_aider() {
  local dir="$1"
  local msg_file="$2"
  local log_file="$3"
  local safe="$4"

  (
    cd "$dir"

    local readonly_args=()
    declare -A read_seen=()
    add_read() {
      local f="$1"
      [[ -n "$f" ]] || return 0
      f="${f#./}"
      [[ -n "$f" ]] || return 0
      [[ -f "$f" ]] || return 0
      if [[ -z "${read_seen["$f"]+x}" ]]; then
        read_seen["$f"]=1
        readonly_args+=(--read "$f")
      fi
    }

    # Add high-signal + representative + random context files (can be in subdirectories).
    local -a ctx_files=()
    mapfile -t ctx_files < <(collect_context_files 8 || true)
    local cf
    for cf in "${ctx_files[@]}"; do
      add_read "$cf"
    done

    # Ensure at least one context file is provided.
    if [[ "${#readonly_args[@]}" -eq 0 ]]; then
      if [[ -f README.md ]]; then
        add_read "README.md"
      else
        cf="$(find_pruned -type f -print 2>/dev/null | head -n 1 || true)"
        [[ -n "$cf" ]] && add_read "$cf"
      fi
    fi

    # Decide edit targets based on what's present (avoid forcing .git/description in non-git folders/monorepo subdirs).
    local -a edit_targets=(README.md)
    [[ -f .git/description ]] && edit_targets+=(".git/description")

    # Only use --subtree-only when inside a git worktree; helps in monorepos but shouldn't break non-git folders.
    local subtree_args=()
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      subtree_args+=(--subtree-only)
    fi

    timeout "$TIMEOUT" aider \
      --model "$MODEL" \
      --api-key "openrouter=$API_KEY" \
      --yes-always \
      --edit-format diff \
      --no-gitignore --no-add-gitignore-files \
      --no-browser --no-detect-urls \
      --no-show-model-warnings \
      --no-check-update --no-show-release-notes \
      --no-analytics --no-auto-commits \
      --chat-history-file /dev/null \
      --input-history-file /dev/null \
      --llm-history-file /dev/null \
      --no-restore-chat-history \
      "${subtree_args[@]}" \
      --message-file "$msg_file" \
      "${readonly_args[@]}" \
      "${edit_targets[@]}"
  ) >"$log_file" 2>&1
}

extract_readme_from_log() {
  # Extract README content from aider logs that use diff format
  # Pattern: "README.md" section followed by "<<<<<<< SEARCH" ... "=======" ... "▌ ▌ ▌ ▌ ▌ ▌ ▌ REPLACE"
  local log_file="$1"
  local out_file="$2"

  # Input validation
  if [[ -z "$log_file" || -z "$out_file" ]]; then
    echo "Error: extract_readme_from_log requires log_file and out_file parameters" >&2
    return 1
  fi

  if [[ ! -f "$log_file" ]]; then
    echo "Error: log file not found: $log_file" >&2
    return 1
  fi

  # Clear/create output file
  > "$out_file"

  awk '
    function strip_prefix(s) {
      sub(/^[[:space:]]*(ASSISTANT|USER)[[:space:]]+/, "", s)
      return s
    }
    function is_metadata_line(s) {
      # Check for various metadata/system message patterns
      if (s ~ /^Applied edit to/) return 1
      if (s ~ /^File.*created/) return 1
      if (s ~ /^File.*deleted/) return 1
      if (s ~ /^Traceback/) return 1
      if (s ~ /^SyntaxError/) return 1
      if (s ~ /^Error:/) return 1
      if (s ~ /^Warning:/) return 1
      # Handle both regular and markdown header forms
      if (s ~ /^\s*#{1,6}\s*Tokens?:/) return 1
      if (s ~ /^\s*Tokens?:/) return 1
      if (s ~ /^\s*#{1,6}\s*Cost:/) return 1
      if (s ~ /^\s*Cost:/) return 1
      if (s ~ /^\s*#{1,6}\s*Model:/) return 1
      if (s ~ /^\s*Model:/) return 1
      if (s ~ /^\s*#{1,6}\s*Temperature:/) return 1
      if (s ~ /^\s*Temperature:/) return 1
      if (s ~ /^\s*#{1,6}\s*Max tokens:/) return 1
      if (s ~ /^\s*Max tokens:/) return 1
      if (s ~ /^\s*#{1,6}\s*Used tokens:/) return 1
      if (s ~ /^\s*Used tokens:/) return 1
      if (s ~ /^\s*#{1,6}\s*Remaining tokens:/) return 1
      if (s ~ /^\s*Remaining tokens:/) return 1
      if (s ~ /^\s*API response/) return 1
      if (s ~ /^\s*HTTP status/) return 1
      if (s ~ /^\s*curl /) return 1
      if (s ~ /^\s*wget /) return 1
      return 0
    }
    function is_command_line(s) {
      # Check for command execution patterns
      if (s ~ /^\s*(python3|python|node|npm|yarn|pip|poetry|go|cargo|make|docker|docker-compose)\s+\w+/) return 1
      if (s ~ /^\s*# Command/) return 1
      if (s ~ /^\s*# Running/) return 1
      if (s ~ /^\s*# Installing/) return 1
      if (s ~ /^\s*# Building/) return 1
      return 0
    }
    BEGIN {
      in_readme_section=0
      in_diff_block=0
      captured_content=""
      line_count=0
      saw_separator=0
      errors=0
    }
    {
      line=$0
      gsub(/\r$/, "", line)
      line2=strip_prefix(line)

      # Reset state if we hit a new file section
      if (line2 ~ /^\.git\/description[[:space:]]*$/) {
        in_readme_section=0
        in_diff_block=0
        saw_separator=0
        content_buffer=""
        line_count=0
        next
      }

      # Track if we are in README.md section
      if (line2 ~ /^README\.md[[:space:]]*$/) {
        in_readme_section=1
        next
      }

      # If in README section and see diff markers, start capturing
      if (in_readme_section) {
        if (line2 ~ /^<<<<<<< SEARCH/) {
          in_diff_block=1
          content_buffer=""
          line_count=0
          next
        }
        
        # Found the separator, start capturing content after this
        if (in_diff_block && line2 ~ /^=======[[:space:]]*$/) {
          saw_separator=1
          next
        }
        
        # End of diff block - handle both patterns
        if (in_diff_block && (line2 ~ /^▌ ▌ ▌ ▌ ▌ ▌ ▌ REPLACE/ || line2 ~ /^>>>>>>> REPLACE/)) {
          # Accept if we captured some reasonable content (at least 1 line after separator)
          if (saw_separator && line_count > 0) {
            captured_content=content_buffer
          }
          in_diff_block=0
          in_readme_section=0
          saw_separator=0
          next
        }
        
        # Capture content after separator
        if (in_diff_block && saw_separator) {
          # Only capture lines that are not metadata or commands
          if (!is_metadata_line(line2) && !is_command_line(line2)) {
            # Preserve all other content including markdown syntax (backticks, headers, etc.)
            content_buffer = content_buffer line2 "\n"
            line_count++
          }
        }
      }
    }
    END {
      if (captured_content != "") {
        printf "%s", captured_content
      } else if (errors > 0) {
        print "" > "/dev/stderr"
      }
    }
  ' "$log_file" > "$out_file" 2>/dev/null

  # Check if extraction was successful
  if [[ ! -s "$out_file" ]]; then
    # Try alternative extraction method for edge cases
    if grep -q "README\.md" "$log_file" 2>/dev/null; then
      # Fallback: extract everything between ======= and the first REPLACE marker
      awk '
        /README\.md/ { in_readme=1 }
        /\.git\/description/ { in_readme=0 }
        in_readme && /^=======/ { capture=1; next }
        capture && (/^▌ ▌ ▌ ▌ ▌ ▌ ▌ REPLACE/ || /^>>>>>>> REPLACE/) { exit }
        capture { print }
      ' "$log_file" > "$out_file" 2>/dev/null || true
    fi
  fi

  [[ -s "$out_file" ]]
}

process_one_repo() {
  local dir="$1"
  local base
  base="$(basename "$dir")"

  local safe="${base//[^A-Za-z0-9._-]/_}"
  while [[ "${safe}" == .* ]]; do safe="${safe#.}"; done
  [[ -n "$safe" ]] || safe="repo"

  local log_file="$LOG_DIR/${safe}.log"
  local result_file="$RESULTS_DIR/${safe}.tsv"
  local extracted_readme="$TMP_DIR/${safe}.README.extracted.md"
  local msg_file="$TMP_DIR/${safe}.message.txt"

  echo "START  $base"

  local has_local_git=0
  if [[ -d "$dir/.git" ]]; then
    has_local_git=1
  fi

  local utc_iso start end dur
  utc_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dur=0

  if [[ $DRY_RUN -eq 0 ]]; then
    (
      cd "$dir"
      echo "DEBUG: Setting up repository: $dir" >&2
      
      ensure_gitignore_has_aider
      echo "DEBUG: .gitignore check/updates completed" >&2
      
      write_apache_license
      echo "DEBUG: Apache license written" >&2
      
      if [[ ! -f README.md ]]; then
        echo "DEBUG: Created empty README.md" >&2
        : > README.md
      else
        echo "DEBUG: README.md already exists" >&2
      fi
      
      if [[ $has_local_git -eq 1 ]]; then
        if [[ ! -f .git/description ]]; then
          echo "DEBUG: Created empty .git/description" >&2
          : > .git/description
        else
          echo "DEBUG: .git/description already exists" >&2
        fi
      else
        echo "DEBUG: No local .git; skipping .git/description setup" >&2
      fi
      
      echo "DEBUG: Setup complete, checking git status" >&2
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git status --porcelain >&2 || echo "DEBUG: git status failed" >&2
      else
        echo "DEBUG: Not a git worktree; skipping git status" >&2
      fi
    )
  fi

  local last
  last="$(state_last_status "$base" || true)"

  local aider_status="skipped_ok"
  local aider_rc=0
  local forced_apply="no"

  if [[ "$last" != "aider_ok" || $FORCE -eq 1 ]]; then
    aider_status="ran"
    start="$(date +%s)"

    if [[ $DRY_RUN -eq 1 ]]; then
      aider_rc=0
    else
      (
        cd "$dir"
        build_message_file "$base" "$msg_file"

        local before_hash after_hash
        before_hash="$(sha_file README.md)"
        echo "DEBUG: Before aider - README.md hash: '$before_hash'" >&2
        echo "DEBUG: Before aider - README.md size: $(wc -l < README.md 2>/dev/null || echo 'N/A') lines" >&2

        set +e
        run_aider "$dir" "$msg_file" "$log_file" "$safe"
        aider_rc=$?
        set -e

        # FIXED: Ensure file system synchronization to prevent caching issues
        echo "DEBUG: Syncing filesystem to ensure file writes are completed" >&2
        sync README.md .git/description 2>/dev/null || true
        sync . 2>/dev/null || true
        sleep 0.1  # Small delay to ensure write completion

        after_hash="$(sha_file README.md)"
        echo "DEBUG: After aider - README.md hash: '$after_hash'" >&2
        echo "DEBUG: After aider - README.md size: $(wc -l < README.md 2>/dev/null || echo 'N/A') lines" >&2
        echo "DEBUG: Aider exit code: $aider_rc" >&2

        if [[ "$before_hash" == "$after_hash" ]]; then
          echo "DEBUG: README.md hash unchanged by aider" >&2
          if extract_readme_from_log "$log_file" "$extracted_readme"; then
            local extracted_hash
            extracted_hash="$(sha_file "$extracted_readme")"
            echo "DEBUG: Extracted README hash: '$extracted_hash'" >&2
            if [[ -n "$extracted_hash" && "$extracted_hash" != "$after_hash" ]]; then
              echo "DEBUG: Applying extracted README content" >&2
              cat "$extracted_readme" > README.md
              forced_apply="yes"
              # Sync again after applying extracted content
              sync README.md 2>/dev/null || true
            else
              echo "DEBUG: No extracted content to apply" >&2
            fi
          else
            echo "DEBUG: Failed to extract README from log" >&2
          fi
        else
          echo "DEBUG: README.md was modified by aider" >&2
        fi
      )
    fi

    end="$(date +%s)"
    dur="$((end - start))"

    if [[ "$aider_rc" -eq 0 ]]; then
      aider_status="ok"
      [[ $DRY_RUN -eq 1 ]] || state_append "$base" "aider_ok" "$utc_iso" "$dur" "$aider_rc" "$MODEL" "log=$log_file forced_apply=$forced_apply"
    else
      aider_status="fail"
      [[ $DRY_RUN -eq 1 ]] || {
        state_append "$base" "aider_fail" "$utc_iso" "$dur" "$aider_rc" "$MODEL" "log=$log_file forced_apply=$forced_apply"
        track_failed_repo "$base"
      }
      printf "%s\t%s\t%s\t%s\t%s\n" "$base" "$aider_status" "$aider_rc" "commit_skipped" "$dur" > "$result_file"
      echo "DONE   $base (aider_fail rc=$aider_rc, log=$log_file)"
      return 0
    fi
  fi

  # Commit changes
  local commit_status="no_changes"
  local commit_rc=0

  if [[ $DRY_RUN -eq 1 ]]; then
    commit_status="dry_run"
  else
    if [[ $has_local_git -ne 1 ]]; then
      commit_status="commit_skipped"
      printf "%s\t%s\t%s\t%s\t%s\n" "$base" "$aider_status" "$aider_rc" "$commit_status" "$dur" > "$result_file"
      echo "DONE   $base (aider=$aider_status rc=$aider_rc, commit=$commit_status, dur=${dur}s)"
      return 0
    fi
    (
      cd "$dir"
      git add -A
      
      # Debug: Check what files are staged
      local staged_files
      staged_files=$(git diff --cached --name-only)
      echo "DEBUG: Staged files: '$staged_files'" >&2
      
      if git diff --cached --quiet; then
        echo "DEBUG: No staged changes detected, exiting commit process" >&2
        exit 0
      fi
      
      echo "DEBUG: Attempting commit with message" >&2
      git commit --no-gpg-sign -m "docs: refresh README, add Apache-2.0 license, ignore .aider*, update git description"
    ) >/dev/null 2>&1 || commit_rc=$?

    echo "DEBUG: Commit exit code: $commit_rc" >&2

    if [[ "$commit_rc" -eq 0 ]]; then
      # If there were changes staged, we committed; if not, we exited 0 earlier.
      if (cd "$dir" && git diff --quiet && git diff --cached --quiet); then
        # no staged diffs left, but still might have been no-op; check if HEAD changed is hard here,
        # so we trust the earlier "diff --cached" gate:
        commit_status="committed"
        echo "DEBUG: Changes were committed successfully" >&2
      else
        echo "DEBUG: No changes after commit attempt" >&2
      fi
    else
      commit_status="commit_fail"
      echo "DEBUG: Commit failed with exit code $commit_rc" >&2
    fi

    # Fix false-positive: if there were actually no staged changes, keep no_changes
    if (cd "$dir" && git diff --cached --quiet); then
      commit_status="no_changes"
      commit_rc=0
      echo "DEBUG: Confirmed no staged changes, setting commit_status=no_changes" >&2
    fi
  fi

  printf "%s\t%s\t%s\t%s\t%s\n" "$base" "$aider_status" "$aider_rc" "$commit_status" "$dur" > "$result_file"
  echo "DONE   $base (aider=$aider_status rc=$aider_rc, commit=$commit_status, dur=${dur}s)"
}

export -f process_one_repo \
  ensure_gitignore_has_aider write_apache_license write_git_description \
  state_append state_last_status track_failed_repo get_failed_repos clear_failed_repos \
  sha_file build_message_file run_aider extract_readme_from_log

export REPO_DIR MODEL API_KEY DRY_RUN FORCE TIMEOUT RETRY LOCK_FILE STATE_FILE LOG_DIR RESULTS_DIR RUN_ID TMP_DIR

mapfile -d '' DIRS < <(
  find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.aider-batch' \
    -print0
)

echo "Run id: $RUN_ID"
echo "Repo root: $REPO_DIR"
echo "Jobs: $JOBS"
echo "Timeout: ${TIMEOUT}s per repository"
echo "Retry: ${RETRY} attempt(s) for failed repos"
echo "Logs: $LOG_DIR"
echo "Checkpoint: $STATE_FILE"
echo "Queued: ${#DIRS[@]} folders"
echo

printf '%s\0' "${DIRS[@]}" | xargs -0 -n1 -P "$JOBS" bash -c 'process_one_repo "$1"' _

# Handle retries if any failed repositories and retries are enabled
if [[ $RETRY -gt 0 ]]; then
  local failed_repos
  failed_repos=($(get_failed_repos))
  
  if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo
    echo "Retrying ${#failed_repos[@]} failed repository(ies)..."
    echo "Failed repos: ${failed_repos[*]}"
    echo
    
    # Process failed repositories for retry
    printf '%s\0' "${failed_repos[@]}" | xargs -0 -n1 -P "$JOBS" bash -c 'process_one_repo "$1"' _
    
    # Clear the failed repos list after retry processing
    clear_failed_repos
  fi
fi

# Summary
aider_ok=0
aider_fail=0
aider_skipped_ok=0
retry_ok=0
retry_fail=0
commit_committed=0
commit_no_changes=0
commit_fail=0
skip_nonrepo=0

while IFS=$'\t' read -r base aider_status aider_rc commit_status dur; do
  [[ -n "${base:-}" ]] || continue
  case "$aider_status" in
    ok) ((aider_ok+=1)) ;;
    fail) ((aider_fail+=1)) ;;
    skipped_ok) ((aider_skipped_ok+=1)) ;;
    skip_nonrepo) ((skip_nonrepo+=1)) ;;
  esac
  case "$commit_status" in
    committed) ((commit_committed+=1)) ;;
    no_changes) ((commit_no_changes+=1)) ;;
    commit_fail) ((commit_fail+=1)) ;;
  esac
done < <(find "$RESULTS_DIR" -maxdepth 1 -type f -name '*.tsv' -print0 2>/dev/null | xargs -0 cat 2>/dev/null || true)

# Count retry results separately if retries were performed
if [[ $RETRY -gt 0 ]]; then
  local retry_results_file="$RESULTS_DIR/retry_results.tsv"
  if [[ -f "$retry_results_file" ]]; then
    while IFS=$'\t' read -r base aider_status aider_rc commit_status dur; do
      [[ -n "${base:-}" ]] || continue
      case "$aider_status" in
        ok) ((retry_ok+=1)) ;;
        fail) ((retry_fail+=1)) ;;
      esac
    done < "$retry_results_file"
  fi
fi

echo
echo "==================== Summary ===================="
echo "Queued folders:         ${#DIRS[@]}"
echo "Non-repos skipped:      $skip_nonrepo"
echo
echo "Aider OK:               $aider_ok"
echo "Aider FAIL:             $aider_fail"
echo "Aider skipped (OK):     $aider_skipped_ok"

if [[ $RETRY -gt 0 && (${retry_ok:-0} -gt 0 || ${retry_fail:-0} -gt 0) ]]; then
  echo
  echo "Retry Results:"
  echo "Retry OK:               $retry_ok"
  echo "Retry FAIL:             $retry_fail"
fi

echo
echo "Commits made:           $commit_committed"
echo "No changes to commit:   $commit_no_changes"
echo "Commit failures:        $commit_fail"
echo
echo "Logs folder:            $LOG_DIR"
echo "Results folder:         $RESULTS_DIR"
echo "Checkpoint file:        $STATE_FILE"

if [[ $aider_fail -ne 0 || $commit_fail -ne 0 ]]; then
  exit 1
fi
