#!/bin/bash

# Dependency Installation Script for Secret Scanner and Autofix
# This script installs all required dependencies for the secret scanner

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt &> /dev/null; then
            OS="debian"
        elif command -v yum &> /dev/null; then
            OS="redhat"
        else
            OS="linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        OS="unknown"
    fi
}

# Print colored output
print_status() {
    local status="$1"
    local message="$2"
    case "$status" in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
    esac
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Install jq
install_jq() {
    print_status "INFO" "Installing jq..."
    
    if command_exists jq; then
        print_status "SUCCESS" "jq is already installed"
        return 0
    fi
    
    case "$OS" in
        "debian")
            sudo apt update && sudo apt install -y jq
            ;;
        "redhat")
            sudo yum install -y jq
            ;;
        "macos")
            if command_exists brew; then
                brew install jq
            else
                print_status "ERROR" "Homebrew not found. Please install Homebrew first: https://brew.sh/"
                exit 1
            fi
            ;;
        *)
            print_status "ERROR" "Unsupported OS for automatic jq installation"
            exit 1
            ;;
    esac
    
    print_status "SUCCESS" "jq installed successfully"
}

# Install gitleaks
install_gitleaks() {
    print_status "INFO" "Installing gitleaks..."
    
    if command_exists gitleaks; then
        print_status "SUCCESS" "gitleaks is already installed"
        return 0
    fi
    
    local version="8.18.0"
    local temp_dir=$(mktemp -d)
    
    case "$OS" in
        "debian"|"redhat")
            local arch=$(uname -m)
            case "$arch" in
                "x86_64")
                    local filename="gitleaks_${version}_linux_x64.tar.gz"
                    local url="https://github.com/zricethezav/gitleaks/releases/download/v${version}/${filename}"
                    ;;
                "arm64"|"aarch64")
                    local filename="gitleaks_${version}_linux_arm64.tar.gz"
                    local url="https://github.com/zricethezav/gitleaks/releases/download/v${version}/${filename}"
                    ;;
                *)
                    print_status "ERROR" "Unsupported architecture: $arch"
                    exit 1
                    ;;
            esac
            
            cd "$temp_dir"
            wget "$url" -O "$filename" || curl -L "$url" -o "$filename"
            tar -xzf "$filename"
            sudo mv gitleaks /usr/local/bin/
            ;;
        "macos")
            if command_exists brew; then
                brew install gitleaks
            else
                print_status "ERROR" "Homebrew not found. Please install Homebrew first: https://brew.sh/"
                exit 1
            fi
            ;;
        *)
            print_status "ERROR" "Unsupported OS for automatic gitleaks installation"
            exit 1
            ;;
    esac
    
    # Cleanup
    rm -rf "$temp_dir"
    
    print_status "SUCCESS" "gitleaks installed successfully"
}

# Install trufflehog
install_trufflehog() {
    print_status "INFO" "Installing trufflehog..."
    
    if command_exists trufflehog; then
        print_status "SUCCESS" "trufflehog is already installed"
        return 0
    fi
    
    case "$OS" in
        "debian"|"redhat"|"macos")
            local temp_dir=$(mktemp -d)
            cd "$temp_dir"
            
            # Download and run install script
            curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin
            
            # Cleanup
            rm -rf "$temp_dir"
            ;;
        *)
            print_status "ERROR" "Unsupported OS for automatic trufflehog installation"
            exit 1
            ;;
    esac
    
    print_status "SUCCESS" "trufflehog installed successfully"
}

# Install git-filter-repo
install_git_filter_repo() {
    print_status "INFO" "Installing git-filter-repo..."
    
    if command_exists git-filter-repo || python3 -m git_filter_repo --version &> /dev/null; then
        print_status "SUCCESS" "git-filter-repo is already installed"
        return 0
    fi
    
    # Try pip install first
    if command_exists pip3 || command_exists pip; then
        pip3 install git-filter-repo || pip install git-filter-repo
    else
        print_status "ERROR" "pip not found. Please install Python pip first."
        exit 1
    fi
    
    print_status "SUCCESS" "git-filter-repo installed successfully"
}

# Check Python and pip
check_python() {
    if ! command_exists python3; then
        print_status "ERROR" "Python 3 is not installed. Please install Python 3 first."
        exit 1
    fi
    
    if ! command_exists pip3 && ! command_exists pip; then
        print_status "ERROR" "pip is not installed. Please install pip first."
        exit 1
    fi
}

# Main installation function
main() {
    echo "Secret Scanner and Autofix - Dependency Installer"
    echo "=================================================="
    echo
    
    detect_os
    print_status "INFO" "Detected OS: $OS"
    echo
    
    # Check if running as root for system-wide installation
    if [[ $EUID -eq 0 ]]; then
        print_status "WARN" "Running as root. This will install tools system-wide."
    fi
    
    # Check Python
    check_python
    
    # Install dependencies
    print_status "INFO" "Starting installation of dependencies..."
    echo
    
    install_jq
    echo
    
    install_gitleaks
    echo
    
    install_trufflehog
    echo
    
    install_git_filter_repo
    echo
    
    # Verify installation
    print_status "INFO" "Verifying installation..."
    echo
    
    local all_installed=true
    
    for tool in jq gitleaks trufflehog git-filter-repo; do
        if command_exists "$tool" || [[ "$tool" == "git-filter-repo" && python3 -m git_filter_repo --version &> /dev/null ]]; then
            print_status "SUCCESS" "$tool is installed"
        else
            print_status "ERROR" "$tool installation failed"
            all_installed=false
        fi
    done
    
    echo
    
    if [ "$all_installed" = true ]; then
        print_status "SUCCESS" "All dependencies installed successfully!"
        echo
        print_status "INFO" "You can now run the secret scanner:"
        echo "  ./secret-scanner-autofix.sh /path/to/repo --dry-run"
    else
        print_status "ERROR" "Some dependencies failed to install. Please check the error messages above."
        exit 1
    fi
}

# Help function
show_help() {
    cat << EOF
Secret Scanner and Autofix - Dependency Installer

Usage: $0 [OPTIONS]

Options:
    -h, --help    Show this help message

This script installs all required dependencies for the Secret Scanner and Autofix script:
- jq (JSON processor)
- gitleaks (Secret detection tool)
- trufflehog (Advanced secret scanning tool)
- git-filter-repo (Git history rewriting tool)

Supported operating systems:
- Ubuntu/Debian (with apt)
- CentOS/RHEL (with yum)
- macOS (with Homebrew)

Requirements:
- Python 3 and pip
- Internet connection for downloading tools
- Sudo privileges for system-wide installation

EOF
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        main "$@"
        ;;
    *)
        print_status "ERROR" "Unknown option: $1"
        show_help
        exit 1
        ;;
esac