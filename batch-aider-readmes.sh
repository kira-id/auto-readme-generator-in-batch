#!/usr/bin/env bash
set -euo pipefail

MODEL_DEFAULT="mistralai/devstral-2512:free"

JOBS_DEFAULT="$(
  getconf _NPROCESSORS_ONLN 2>/dev/null \
  || nproc 2>/dev/null \
  || echo 4
)"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --api-key <OPENROUTER_KEY> [--model <MODEL_NAME>] [--repo <PATH>] [--jobs N] [--dry-run] [--force]

Options:
  --api-key   Required. OpenRouter API key.
  --model     Optional. Default: ${MODEL_DEFAULT}
  --repo      Optional. Default: ./repo (relative to current dir) or ./repo next to this script if found
  --jobs      Optional. Parallel workers. Default: ${JOBS_DEFAULT}
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

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf of
      any other Contributor, and only if You agree to indemnify, defend,
      and hold each Contributor harmless for any liability incurred by, or
      claims asserted against, such Contributor by reason of your accepting
      any such warranty or additional liability.

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

build_message_file() {
  local repo_name="$1"
  local msg_file="$2"

  {
    printf '%s\n\n' "Rewrite README.md using a WHOLE-FILE replacement and update .git/description."
    printf '%s\n' "Hard rules:"
    printf '%s\n' "- Edit README.md and .git/description."
    printf '%s\n' "- Keep claims strictly accurate to files in this folder. Do not invent features."
    printf '%s\n' "- Produce a useful end-user README with these sections: why this repo, background on what situation this solution fits, use cases, quick start, detailed installation and usage, development progress, what this repository not yet solved, contributing."
    printf '%s\n' "- Include a License section: Apache-2.0 and a LICENSE file exists."
    printf '%s\n' "- Use the existing README.md as context, but do not keep generic placeholders if code reveals concrete behavior."
    printf '%s\n' "- Do NOT create any new files. Do NOT interpret command examples (like 'python3 script.py') as file creation commands."
    printf '%s\n' "- Command examples in markdown code blocks are documentation, not instructions to create files."
    printf '%s\n' "- Repository content must be engaging, clear, and descriptive."
    printf '%s\n' "- The first line should be a descriptive title (not '# repo-folder-name'). Create a compelling, descriptive title that reflects the repository'\''s purpose."
    printf '%s\n' "- Do NOT start with an 'Overview' heading - go straight to content."
    printf '%s\n' "- Write a concise, descriptive summary for .git/description that captures the essence of this repository."
    printf 'Repository: %s\n\n' "$repo_name"
    printf '%s\n' "Original README.md (context):"
    printf '%s\n' '```markdown'
    if [[ -f README.md ]]; then
      cat README.md
    fi
    printf '\n%s\n' '```'
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
    for f in \
      package.json pnpm-lock.yaml yarn.lock package-lock.json \
      pyproject.toml poetry.lock requirements.txt setup.py setup.cfg \
      Cargo.toml Cargo.lock go.mod go.sum \
      pom.xml build.gradle settings.gradle gradle.properties \
      Gemfile Gemfile.lock composer.json composer.lock \
      Makefile Dockerfile docker-compose.yml docker-compose.yaml compose.yml \
      CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md CHANGELOG.md \
      install.sh tick-emulator.py
    do
      [[ -f "$f" ]] && readonly_args+=(--read "$f")
    done

    aider \
      --model "$MODEL" \
      --api-key "openrouter=$API_KEY" \
      --yes-always \
      --edit-format whole \
      --no-gitignore --no-add-gitignore-files \
      --no-browser --no-detect-urls \
      --no-show-model-warnings \
      --no-check-update --no-show-release-notes \
      --no-analytics --no-auto-commits \
      --subtree-only \
      --message-file "$msg_file" \
      "${readonly_args[@]}" \
      README.md .git/description
  ) >"$log_file" 2>&1
}

extract_readme_from_log() {
  # Extract the last fenced block that follows a README.md header line.
  local log_file="$1"
  local out_file="$2"

  awk '
    function strip_prefix(s) {
      sub(/^[[:space:]]*(ASSISTANT|USER)[[:space:]]+/, "", s)
      return s
    }
    BEGIN { want=0; cap=0; buf=""; last=""; line_count=0 }
    {
      line=$0
      gsub(/\r$/, "", line)
      line2=strip_prefix(line)

      if (cap==0) {
        # Accept: "README.md", "README.md:", "README.md (something)"
        # Be more strict: only match if followed by a fence within reasonable distance
        if (line2 ~ /^README\.md([[:space:]]*[:(].*)?[[:space:]]*$/) {
          want=1;
          next
        }
        if (want==1 && line2 ~ /^```/) {
          cap=1;
          buf="";
          line_count=0;
          next
        }
        want=0
        next
      }

      # cap==1 - capturing content
      if (line2 ~ /^```[[:space:]]*$/) {
        # Only accept if we captured a reasonable amount of content (at least 5 lines)
        if (line_count >= 5) {
          last=buf
        }
        cap=0
        want=0
        next
      }

      # Skip lines that look like file operations or commands
      if (line2 ~ /^(python3|npm|node|yarn|pip|go|cargo|make)\s+\w+/ ||
          line2 ~ /^Applied edit to/ ||
          line2 ~ /^File.*created/ ||
          line2 ~ /^Traceback/ ||
          line2 ~ /^SyntaxError/ ||
          line2 ~ /^```/) {
        next
      }

      buf = buf line2 "\n"
      line_count++
    }
    END {
      if (last != "") printf "%s", last
    }
  ' "$log_file" > "$out_file"

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

  if [[ ! -d "$dir/.git" ]]; then
    printf "%s\t%s\t%s\t%s\t%s\n" "$base" "skip_nonrepo" "-" "commit_skipped" "-" > "$result_file"
    echo "DONE   $base (skip_nonrepo)"
    return 0
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
      
      if [[ ! -f .git/description ]]; then
        echo "DEBUG: Created empty .git/description" >&2
        : > .git/description
      else
        echo "DEBUG: .git/description already exists" >&2
      fi
      
      echo "DEBUG: Setup complete, checking git status" >&2
      git status --porcelain >&2 || echo "DEBUG: git status failed" >&2
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
      [[ $DRY_RUN -eq 1 ]] || state_append "$base" "aider_fail" "$utc_iso" "$dur" "$aider_rc" "$MODEL" "log=$log_file forced_apply=$forced_apply"
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
  state_append state_last_status sha_file build_message_file run_aider \
  extract_readme_from_log

export REPO_DIR MODEL API_KEY DRY_RUN FORCE LOCK_FILE STATE_FILE LOG_DIR RESULTS_DIR RUN_ID TMP_DIR

mapfile -d '' DIRS < <(
  find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.aider-batch' \
    -print0
)

echo "Run id: $RUN_ID"
echo "Repo root: $REPO_DIR"
echo "Jobs: $JOBS"
echo "Logs: $LOG_DIR"
echo "Checkpoint: $STATE_FILE"
echo "Queued: ${#DIRS[@]} folders"
echo

printf '%s\0' "${DIRS[@]}" | xargs -0 -n1 -P "$JOBS" bash -c 'process_one_repo "$1"' _

# Summary
aider_ok=0
aider_fail=0
aider_skipped_ok=0
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

echo
echo "==================== Summary ===================="
echo "Queued folders:         ${#DIRS[@]}"
echo "Non-repos skipped:      $skip_nonrepo"
echo
echo "Aider OK:               $aider_ok"
echo "Aider FAIL:             $aider_fail"
echo "Aider skipped (OK):     $aider_skipped_ok"
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
