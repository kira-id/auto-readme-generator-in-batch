# Repository Management and Security Automation Suite

A comprehensive collection of bash scripts for automated repository management, security scanning, and batch operations across multiple Git repositories.

## Features

### 📝 Automated README Generation with AI
- **AI-Powered README Enhancement**: Uses Aider with OpenRouter API to automatically improve and generate README files across multiple repositories
- **Smart Context Analysis**: Intelligently analyzes repository structure and code to generate accurate documentation
  - Prioritizes high-signal configuration files (package.json, tsconfig.json, etc.)
  - Analyzes representative source files from src/, app/, pages/, server/, lib/ directories
  - Handles multiple project types: JavaScript/TypeScript, Python, Go, Rust, Java, and more
- **Batch Processing**: Process hundreds of repositories in parallel with configurable job limits
- **State Management**: Checkpoint system allows resuming interrupted operations
- **License Management**: Automatically adds Apache 2.0 licenses to repositories
- **Intelligent Retry Logic**: Automatic retry of failed repositories with configurable attempts

### 🔒 Secret Detection and Remediation
- **Multi-Tool Secret Scanning**: Combines gitleaks and trufflehog for comprehensive secret detection
- **Git History Cleaning**: Removes secrets from entire git history using git-filter-repo
- **Current Files Only Mode**: Option to clean only current tracked files without history rewriting
- **Parallel Processing**: Scan multiple repositories simultaneously for efficiency
- **Automated Replacement**: Intelligently replaces detected secrets with safe placeholders

### 🚀 Batch Repository Operations
- **Parallel Git Operations**: Commit and push changes across multiple repositories concurrently
- **GitHub Integration**: Automatically creates repositories and manages remote configurations
- **Smart Remote Handling**: Safely migrates existing remotes to prevent conflicts
- **Flexible Authentication**: Supports both GitHub CLI and personal access tokens

### ⚙️ Dependency Management
- **Cross-Platform Support**: Works on Linux, macOS, and supports multiple package managers
- **Automated Tool Installation**: Installs gitleaks, trufflehog, jq, and git-filter-repo
- **Dependency Verification**: Ensures all required tools are properly installed before execution

## Scripts Overview

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `batch-aider-readmes.sh` | AI-powered README generation and improvement | OpenRouter AI integration, parallel processing, state management, context analysis, retry logic, license auto-generation |
| `secret-scanner-autofix.sh` | Secret detection and removal from repositories | Multi-tool scanning, git history cleaning, current files mode, automated replacement |
| `parallel-secret-scanner.sh` | Batch secret scanning across multiple repositories | Parallel processing, summary reports, resume capability |
| `batch-commit-and-push.sh` | Batch commit and push operations to GitHub | Repository creation, remote management, parallel operations |
| `install-dependencies.sh` | Install all required dependencies | Cross-platform support, dependency verification |

## Installation

### Quick Setup

1. **Clone or download this repository:**
   ```bash
   git clone <repository-url>
   cd opensource-transfer
   ```

2. **Install dependencies:**
   ```bash
   chmod +x install-dependencies.sh
   ./install-dependencies.sh
   ```

3. **Configure required API keys:**
   - **OpenRouter API Key** (for AI-powered README generation)
   - **GitHub Token** (for repository operations)

### Prerequisites

- **Git**: For repository operations
- **Python 3**: Required by git-filter-repo
- **jq**: JSON processor for script functionality
- **Aider**: AI coding assistant for README generation
- **OpenRouter API Access**: For AI-powered README generation
- **GitHub CLI** (optional): Enhanced GitHub integration

## Usage Examples

### AI-Powered README Generation (`batch-aider-readmes.sh`)

Generate and improve README files across all repositories in the `repo/` directory:

```bash
./batch-aider-readmes.sh --api-key YOUR_OPENROUTER_KEY --jobs 4
```

**Advanced Usage:**
```bash
# Process specific directory with custom model and settings
./batch-aider-readmes.sh \
  --api-key YOUR_OPENROUTER_KEY \
  --model mistralai/devstral-2512:free \
  --repo ./custom-repo-path \
  --jobs 8 \
  --timeout 600 \
  --retry 2

# Force re-run even if previously successful
./batch-aider-readmes.sh \
  --api-key YOUR_OPENROUTER_KEY \
  --force

# Dry run to see what would be processed
./batch-aider-readmes.sh \
  --api-key YOUR_OPENROUTER_KEY \
  --dry-run
```

**Key Features of README Generation:**
- **Smart Context Collection**: Analyzes project structure and prioritizes important files
- **State Management**: Uses checkpoints to track progress and enable resumability
- **Apache 2.0 License**: Automatically adds license files to repositories
- **Git Integration**: Updates .gitignore and .git/description files
- **Comprehensive Logging**: Detailed logs with performance metrics
- **Error Recovery**: Automatic retry logic for failed repositories

### Secret Scanning and Remediation

Scan a single repository for secrets:

```bash
./secret-scanner-autofix.sh /path/to/repository
```

**Scanning Modes:**
```bash
# Dry run - simulation only
./secret-scanner-autofix.sh /path/to/repo --dry-run

# Scan current files only (no history rewriting)
./secret-scanner-autofix.sh /path/to/repo --no-history

# Full scan with history flattening
./secret-scanner-autofix.sh /path/to/repo --flatten
```

### Batch Secret Scanning

Scan all repositories in `repo/` directory in parallel:

```bash
./parallel-secret-scanner.sh
```

**Advanced Options:**
```bash
# Parallel scanning with custom settings
./parallel-secret-scanner.sh \
  --jobs 8 \
  --dry-run \
  --verbose \
  --resume

# Process specific repository
./parallel-secret-scanner.sh --process-single /path/to/repo
```

### Batch Repository Operations

Commit and push changes to GitHub:

```bash
./batch-commit-and-push.sh \
  --repo-dir ./repo \
  --org your-org \
  --token YOUR_GITHUB_TOKEN \
  --jobs 4
```

**Repository Creation:**
```bash
# Create repositories if they don't exist
./batch-commit-and-push.sh \
  --org your-org \
  --visibility public \
  --desc-mode auto
```

## Configuration

### Environment Variables

- `DRY_RUN`: Set to `true` for simulation mode (no actual changes)
- `VERBOSE`: Enable detailed logging
- `FORCE`: Override safety checks and force execution

### API Keys and Authentication

1. **OpenRouter API Key**: 
   - Get from [OpenRouter](https://openrouter.ai/)
   - Required for AI-powered README generation
   - Default model: `mistralai/devstral-2512:free`

2. **GitHub Token**:
   - Create a Personal Access Token with repo permissions
   - Used for repository creation and batch operations

3. **Git Configuration**:
   ```bash
   git config --global user.name "Your Name"
   git config --global user.email "your.email@example.com"
   ```

## Advanced Features

### README Generation Intelligence

The `batch-aider-readmes.sh` script includes sophisticated features:

- **Context File Prioritization**: 
  - Configuration files: package.json, tsconfig.json, vite.config.ts, etc.
  - Build tools: webpack, rollup, svelte, nuxt, astro configs
  - Code quality: eslint, prettier, babel configs
  - Deployment: Dockerfile, docker-compose, vercel.json, etc.
  - Language-specific: pyproject.toml, Cargo.toml, go.mod, pom.xml

- **Source Code Analysis**:
  - TypeScript/JavaScript files from src/, app/, pages/, server/, lib/
  - Representative files to understand project structure
  - Fallback mechanisms for edge cases

- **State Management**:
  - Checkpoint system prevents reprocessing successful repositories
  - Resume capability for interrupted operations
  - Detailed progress tracking with timestamps

### Safety and Reliability

- **Dry Run Mode**: All scripts support `--dry-run` for safe testing
- **Backup Warnings**: Git history rewriting operations include safety warnings
- **Dependency Validation**: Scripts verify required tools before execution
- **Error Handling**: Comprehensive error handling with detailed logging
- **Checkpoint System**: Resume interrupted batch operations
- **File System Synchronization**: Ensures proper write completion

## Directory Structure

```
├── batch-aider-readmes.sh          # AI README generation with context analysis
├── batch-commit-and-push.sh        # Batch GitHub operations
├── secret-scanner-autofix.sh       # Secret detection and removal
├── parallel-secret-scanner.sh      # Parallel secret scanning
├── install-dependencies.sh         # Dependency installation
├── LICENSE                         # Apache 2.0 license
└── README.md                       # This file
```

## Best Practices

1. **Always run in dry-run mode first** to preview changes
2. **Use appropriate timeout values** for large repositories (default: 300s)
3. **Monitor parallel job limits** to avoid system overload
4. **Enable retry logic** for production batch operations
5. **Review AI-generated content** for accuracy and completeness
6. **Backup important repositories** before running history rewriting operations

## Troubleshooting

### Common Issues

1. **Permission Errors**: Ensure scripts are executable (`chmod +x *.sh`)
2. **Missing Dependencies**: Run `./install-dependencies.sh` to install requirements
3. **API Authentication**: Verify OpenRouter and GitHub API keys are valid
4. **Git Configuration**: Ensure user.name and user.email are set globally
5. **Context File Issues**: Check repository structure for recognized file patterns

### Logging and Debugging

All operations generate detailed logs:
- **Main Logs**: Stored in script-specific directories with timestamps
- **Repository Logs**: Individual logs for each processed repository
- **State Files**: Checkpoint system with progress tracking
- **Summary Reports**: Comprehensive reports with success/failure metrics
- **Performance Metrics**: Duration tracking and resource usage

## Contributing

1. Test changes thoroughly with `--dry-run` mode
2. Ensure compatibility across different operating systems
3. Add appropriate error handling and logging
4. Update documentation for new features
5. Follow existing code patterns and conventions

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

---

**Author**: Samuel Koesnadi (samuel@kira.id)
**Version**: 1.0.0