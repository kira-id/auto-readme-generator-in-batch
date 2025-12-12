# Secret Scanner and Autofix Script

A comprehensive bash script that combines **gitleaks** and **trufflehog** for secret detection with automatic git history cleaning using **git-filter-repo**.

## 🚀 Features

- **Dual Scanning**: Combines gitleaks and trufflehog for comprehensive secret detection
- **Automatic Git History Cleaning**: Removes secrets from entire git history using git-filter-repo
- **Dry-Run Mode**: Test the script without making actual changes
- **Comprehensive Logging**: Detailed logs and summary reports
- **Backup Creation**: Automatic backup before cleaning git history
- **Multiple Secret Types**: Detects API keys, passwords, tokens, AWS credentials, and more
- **Safe Operation**: Error handling and graceful failure management

## 📋 Requirements

### Required Tools

Install the following tools before running the script:

1. **gitleaks** - Secret detection tool
   ```bash
   # macOS
   brew install gitleaks
   
   # Linux
   wget https://github.com/zricethezav/gitleaks/releases/download/v8.18.0/gitleaks_8.18.0_linux_x64.tar.gz
   tar -xzf gitleaks_8.18.0_linux_x64.tar.gz
   sudo mv gitleaks /usr/local/bin/
   
   # Docker
   docker pull zricethezav/gitleaks
   ```

2. **trufflehog** - Advanced secret scanning tool
   ```bash
   # macOS
   brew install trufflehog
   
   # Linux
   curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin
   
   # Docker
   docker pull trufflesecurity/trufflehog:latest
   ```

3. **git-filter-repo** - Git history rewriting tool
   ```bash
   # Using pip (recommended)
   pip install git-filter-repo
   
   # Using package manager
   brew install git-filter-repo
   
   # Manual installation
   # Download from: https://github.com/newren/git-filter-repo
   ```

4. **jq** - JSON processor (for parsing scan results)
   ```bash
   # macOS
   brew install jq
   
   # Ubuntu/Debian
   sudo apt install jq
   
   # CentOS/RHEL
   sudo yum install jq
   ```

## 🔧 Installation

1. Download the script:
   ```bash
   wget https://raw.githubusercontent.com/your-repo/secret-scanner-autofix.sh
   chmod +x secret-scanner-autofix.sh
   ```

2. Or clone this repository:
   ```bash
   git clone https://github.com/your-repo/secret-scanner-autofix.git
   cd secret-scanner-autofix
   chmod +x secret-scanner-autofix.sh
   ```

## 📖 Usage

### Basic Usage

```bash
./secret-scanner-autofix.sh <folder_path>
```

### Dry-Run Mode (Recommended for First Use)

```bash
./secret-scanner-autofix.sh <folder_path> --dry-run
```

### Examples

```bash
# Scan and clean current directory
./secret-scanner-autofix.sh .

# Scan a specific repository
./secret-scanner-autofix.sh /path/to/my/repo

# Test without making changes
./secret-scanner-autofix.sh /path/to/my/repo --dry-run

# Show help
./secret-scanner-autofix.sh --help
```

## 📊 What the Script Does

### 1. **Dependency Check**
Verifies all required tools are installed before proceeding.

### 2. **Input Validation**
- Checks if the path exists and is a git repository
- Validates command-line arguments

### 3. **Secret Detection**
- **Gitleaks Scan**: Scans current files and git history for common secret patterns
- **Trufflehog Scan**: Performs advanced secret detection with verification

### 4. **Pattern Extraction**
- Extracts detected secrets from scan results
- Creates replacement patterns for automatic cleaning
- Adds common patterns as fallback

### 5. **Git History Cleaning**
- Creates a backup of the repository
- Uses git-filter-repo to remove secrets from all commits
- Handles all branches and tags

### 6. **Reporting**
- Generates detailed log files
- Creates summary reports with findings and actions taken
- Provides next steps and recommendations

## 📄 Output Files

The script creates several output files:

- `secret-scanner-YYYYMMDD-HHMMSS.log` - Detailed execution log
- `scan-summary-YYYYMMDD-HHMMSS.txt` - Summary report
- `gitleaks-report.json` - Gitleaks scan results
- `trufflehog-report.json` - Trufflehog scan results
- `replacements.txt` - Generated replacement patterns

## 🔍 Detected Secret Types

The script can detect various types of secrets including:

- **API Keys**: Generic API keys, Stripe keys, SendGrid keys
- **AWS Credentials**: Access keys and secret keys
- **Database Passwords**: MySQL, PostgreSQL, MongoDB connections
- **JWT Secrets**: JSON Web Token secrets
- **Private Keys**: SSH keys, certificates
- **Slack Tokens**: Slack bot tokens and webhooks
- **GitHub Tokens**: Personal access tokens
- **Google API Keys**: Various Google service keys
- **Generic Passwords**: Hardcoded password assignments

## ⚠️ Important Considerations

### Backup Your Repository
- The script automatically creates backups, but it's recommended to manually backup your repository first
- Store backups in a secure location

### Force Push Required
After cleaning git history, you'll need to force push to update remote repositories:
```bash
git push --force origin --all
git push --force origin --tags
```

### Coordinate with Team
- Git history rewriting affects all collaborators
- Notify team members before running the script on shared repositories
- Consider using the dry-run mode to preview changes

### Credential Rotation
- **Immediately rotate any exposed credentials** after running the script
- This includes API keys, passwords, tokens, and certificates
- Update configurations with new credentials

### False Positives
- Review scan results for false positives
- Some legitimate content might be flagged as secrets
- Adjust patterns if needed

## 🔧 Advanced Configuration

### Custom Gitleaks Configuration
Create a `.gitleaks.toml` file in your repository root to customize detection rules:

```toml
title = "Gitleaks config"

[[rules]]
id = "custom-api-key"
description = "Custom API key pattern"
regex = '''custom-api-key-[a-zA-Z0-9]{32}'''
```

### Custom Trufflehog Configuration
Trufflehog can be configured with custom detectors and patterns.

## 🐛 Troubleshooting

### Common Issues

1. **"Not a git repository" error**
   - Ensure the path points to a git repository
   - Check if `.git` directory exists

2. **Missing dependencies**
   - Install all required tools as listed in the Requirements section
   - Verify tools are in your PATH

3. **Permission denied**
   - Make the script executable: `chmod +x secret-scanner-autofix.sh`
   - Ensure write permissions in the target directory

4. **Git history not cleaning**
   - Check if git-filter-repo is properly installed
   - Ensure the repository is not protected by branch protection rules

5. **Large repositories**
   - For large repositories, consider running in stages
   - Monitor disk space for backup creation

### Debug Mode
The script includes debug logging. Check the log file for detailed execution information.

## 📝 Example Workflow

1. **Prepare**:
   ```bash
   # Create backup
   cp -r my-repo my-repo-backup
   
   # Run dry-run to preview
   ./secret-scanner-autofix.sh my-repo --dry-run
   ```

2. **Review Results**:
   - Check summary report
   - Review detected secrets for false positives
   - Verify replacement patterns

3. **Execute**:
   ```bash
   # Run actual cleaning
   ./secret-scanner-autofix.sh my-repo
   ```

4. **Update Remote**:
   ```bash
   cd my-repo
   git push --force origin --all
   git push --force origin --tags
   ```

5. **Rotate Credentials**:
   - Immediately update any exposed API keys
   - Regenerate certificates if needed
   - Update team members with new credentials

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## ⚡ Quick Start

```bash
# 1. Install dependencies
brew install gitleaks jq
curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh
pip install git-filter-repo

# 2. Make script executable
chmod +x secret-scanner-autofix.sh

# 3. Run dry-run test
./secret-scanner-autofix.sh /path/to/repo --dry-run

# 4. Review results and run actual cleanup
./secret-scanner-autofix.sh /path/to/repo
```

## 🆘 Support

If you encounter issues or need help:

1. Check the troubleshooting section
2. Review the log files for detailed error information
3. Open an issue with:
   - Your operating system
   - Versions of installed tools
   - Error messages from the log file
   - Steps to reproduce the issue

## 📚 Additional Resources

- [Gitleaks Documentation](https://github.com/zricethezav/gitleaks)
- [Trufflehog Documentation](https://github.com/trufflesecurity/trufflehog)
- [Git-filter-repo Documentation](https://github.com/newren/git-filter-repo)
- [GitHub: Removing sensitive data](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)

---

**⚠️ Remember**: Always test in dry-run mode first and ensure you have proper backups before running the script on important repositories!