#!/usr/bin/env bash
#
# ============================================================================
# DeepTutor Production-Grade Installation Script
# ============================================================================
# Version: 1.0.0
# Author: OpenHands AI Assistant
# License: AGPL-3.0 (same as DeepTutor)
#
# Description:
#   One-click installation utility for DeepTutor - AI-Powered Personalized
#   Learning Assistant. Supports both Docker and native installation modes
#   with systemd process management.
#
# Usage:
#   sudo ./install_pro.sh [OPTIONS]
#   curl -sSL <url>/install_pro.sh | sudo bash -s -- [OPTIONS]
#
# Options:
#   -m, --mode MODE           Installation mode: docker|native (default: docker)
#   -d, --install-dir DIR     Installation directory (default: /opt/deeptutor)
#   -b, --backend-port PORT   Backend API port (default: 8001)
#   -f, --frontend-port PORT  Frontend web port (default: 3782)
#   -e, --env-file FILE       Path to .env file with secrets
#   -u, --user USER           Service user (default: deeptutor)
#   -n, --no-start            Don't start services after installation
#   -r, --repo-url URL        Git repository URL (default: GitHub)
#   -t, --branch BRANCH       Git branch/tag to checkout (default: main)
#   --skip-deps               Skip system dependency installation
#   --dry-run                 Show what would be done without executing
#   -h, --help                Show this help message
#
# Examples:
#   sudo ./install_pro.sh --mode docker --backend-port 9001
#   sudo ./install_pro.sh --mode native --install-dir /srv/deeptutor
#   sudo ./install_pro.sh -m native -e /path/to/.env -b 8001 -f 3782
#
# ============================================================================

set -o pipefail

# ============================================================================
# Configuration Defaults
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly MIN_PYTHON_VERSION="3.10"
readonly MIN_NODE_VERSION="18"
readonly DEFAULT_REPO_URL="https://github.com/HKUDS/DeepTutor.git"
readonly DEFAULT_BRANCH="main"

# Installation defaults
INSTALL_MODE="docker"
INSTALL_DIR="/opt/deeptutor"
BACKEND_PORT="8001"
FRONTEND_PORT="3782"
ENV_FILE=""
SERVICE_USER="deeptutor"
START_SERVICES="true"
REPO_URL="${DEFAULT_REPO_URL}"
GIT_BRANCH="${DEFAULT_BRANCH}"
SKIP_DEPS="false"
DRY_RUN="false"

# Runtime state
TEMP_DIR=""
CLEANUP_NEEDED="false"
LOG_FILE="/var/log/deeptutor-install.log"

# ============================================================================
# Color Definitions (for terminal output)
# ============================================================================

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly BOLD=''
    readonly NC=''
fi

# ============================================================================
# Logging Functions
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    
    # Write to stdout with colors
    case "${level}" in
        INFO)
            echo -e "${BLUE}ℹ ${NC}${message}"
            ;;
        SUCCESS)
            echo -e "${GREEN}✅ ${message}${NC}"
            ;;
        WARNING)
            echo -e "${YELLOW}⚠️  ${message}${NC}"
            ;;
        ERROR)
            echo -e "${RED}❌ ${message}${NC}" >&2
            ;;
        STEP)
            echo -e "\n${BOLD}${CYAN}━━━ ${message} ━━━${NC}\n"
            ;;
        DEBUG)
            if [[ "${DRY_RUN}" == "true" ]]; then
                echo -e "${CYAN}[DRY-RUN] ${message}${NC}"
            fi
            ;;
    esac
}

info() { log INFO "$@"; }
success() { log SUCCESS "$@"; }
warning() { log WARNING "$@"; }
error() { log ERROR "$@"; }
step() { log STEP "$@"; }
debug() { log DEBUG "$@"; }

die() {
    error "$@"
    cleanup
    exit 1
}

# ============================================================================
# Cleanup & Error Handling
# ============================================================================

cleanup() {
    if [[ "${CLEANUP_NEEDED}" == "true" ]]; then
        info "Cleaning up temporary files..."
        [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
    fi
}

trap cleanup EXIT
trap 'die "Installation interrupted by user"' INT TERM

# ============================================================================
# Utility Functions
# ============================================================================

show_help() {
    cat << EOF
${BOLD}DeepTutor Production Installation Script v${SCRIPT_VERSION}${NC}

${BOLD}USAGE:${NC}
    sudo ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS:${NC}
    -m, --mode MODE           Installation mode: docker|native (default: ${INSTALL_MODE})
    -d, --install-dir DIR     Installation directory (default: ${INSTALL_DIR})
    -b, --backend-port PORT   Backend API port (default: ${BACKEND_PORT})
    -f, --frontend-port PORT  Frontend web port (default: ${FRONTEND_PORT})
    -e, --env-file FILE       Path to .env file with secrets
    -u, --user USER           Service user (default: ${SERVICE_USER})
    -n, --no-start            Don't start services after installation
    -r, --repo-url URL        Git repository URL
    -t, --branch BRANCH       Git branch/tag (default: ${GIT_BRANCH})
    --skip-deps               Skip system dependency installation
    --dry-run                 Show what would be done without executing
    -h, --help                Show this help message

${BOLD}ENVIRONMENT VARIABLES:${NC}
    Required for operation (set in .env file or pass via --env-file):
    - LLM_API_KEY             API key for LLM provider
    - LLM_MODEL               Model name (e.g., gpt-4o)
    - LLM_HOST                API endpoint URL
    - EMBEDDING_API_KEY       API key for embeddings
    - EMBEDDING_MODEL         Embedding model name
    - EMBEDDING_HOST          Embedding API endpoint

${BOLD}EXAMPLES:${NC}
    # Docker installation (recommended)
    sudo ${SCRIPT_NAME} --mode docker --env-file /path/to/.env

    # Native installation with custom ports
    sudo ${SCRIPT_NAME} --mode native -b 9001 -f 4000

    # Dry run to see what would happen
    sudo ${SCRIPT_NAME} --mode docker --dry-run

${BOLD}QUICK START:${NC}
    curl -sSL https://raw.githubusercontent.com/HKUDS/DeepTutor/main/install_pro.sh | \\
        sudo bash -s -- --mode docker --backend-port 8001 --frontend-port 3782

EOF
    exit 0
}

version_ge() {
    # Check if $1 >= $2 (version comparison)
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

command_exists() {
    command -v "$1" &>/dev/null
}

run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        debug "Would run: $*"
        return 0
    fi
    "$@"
}

create_directory() {
    local dir="$1"
    local owner="${2:-root}"
    
    if [[ -d "${dir}" ]]; then
        debug "Directory already exists: ${dir}"
        return 0
    fi
    
    run_cmd mkdir -p "${dir}" || die "Failed to create directory: ${dir}"
    run_cmd chown -R "${owner}:${owner}" "${dir}" 2>/dev/null || true
    debug "Created directory: ${dir}"
}

# ============================================================================
# System Detection & Validation
# ============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root. Please use: sudo ${SCRIPT_NAME}"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_PRETTY="${PRETTY_NAME}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
        OS_PRETTY=$(cat /etc/redhat-release)
    else
        die "Unsupported operating system. This script requires Debian/Ubuntu, RHEL/CentOS, or Fedora."
    fi
    
    info "Detected OS: ${OS_PRETTY}"
    
    case "${OS_ID}" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            PKG_UPDATE="apt-get update -qq"
            PKG_INSTALL="apt-get install -y -qq"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command_exists dnf; then
                PKG_MANAGER="dnf"
                PKG_UPDATE="true"  # dnf auto-updates
                PKG_INSTALL="dnf install -y -q"
            else
                PKG_MANAGER="yum"
                PKG_UPDATE="yum makecache -q"
                PKG_INSTALL="yum install -y -q"
            fi
            ;;
        *)
            die "Unsupported distribution: ${OS_ID}. Supported: ubuntu, debian, centos, rhel, fedora"
            ;;
    esac
}

check_architecture() {
    local arch
    arch=$(uname -m)
    
    case "${arch}" in
        x86_64|amd64)
            ARCH="amd64"
            DOCKER_IMAGE_TAG="latest"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            DOCKER_IMAGE_TAG="latest-arm64"
            ;;
        *)
            die "Unsupported architecture: ${arch}. Supported: x86_64, aarch64"
            ;;
    esac
    
    info "Architecture: ${arch} (using tag: ${DOCKER_IMAGE_TAG})"
}

check_systemd() {
    if ! command_exists systemctl; then
        die "systemd is required but not found. This script requires a systemd-based system."
    fi
    
    if ! systemctl is-system-running &>/dev/null; then
        warning "systemd may not be fully operational"
    fi
}

check_memory() {
    local mem_total_kb
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_total_gb=$((mem_total_kb / 1024 / 1024))
    
    if [[ ${mem_total_gb} -lt 4 ]]; then
        warning "System has ${mem_total_gb}GB RAM. Recommended minimum is 4GB."
    else
        info "Memory: ${mem_total_gb}GB RAM"
    fi
}

check_disk_space() {
    local install_parent
    install_parent=$(dirname "${INSTALL_DIR}")
    
    local available_kb
    available_kb=$(df -k "${install_parent}" 2>/dev/null | awk 'NR==2 {print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    
    if [[ ${available_gb} -lt 10 ]]; then
        warning "Only ${available_gb}GB disk space available. Recommended minimum is 10GB."
    else
        info "Disk space: ${available_gb}GB available in ${install_parent}"
    fi
}

# ============================================================================
# Dependency Installation
# ============================================================================

install_system_deps() {
    if [[ "${SKIP_DEPS}" == "true" ]]; then
        info "Skipping system dependency installation (--skip-deps)"
        return 0
    fi
    
    step "Installing System Dependencies"
    
    info "Updating package manager..."
    run_cmd ${PKG_UPDATE} || warning "Package manager update had issues"
    
    local common_packages=(
        curl
        wget
        git
        ca-certificates
        gnupg
        lsb-release
    )
    
    case "${OS_ID}" in
        ubuntu|debian)
            local packages=(
                "${common_packages[@]}"
                build-essential
                libgl1
                libglib2.0-0
                libsm6
                libxext6
                libxrender1
                pkg-config
                libssl-dev
            )
            ;;
        centos|rhel|rocky|almalinux|fedora)
            local packages=(
                "${common_packages[@]}"
                gcc
                gcc-c++
                make
                mesa-libGL
                glib2
                libSM
                libXext
                libXrender
                pkgconfig
                openssl-devel
            )
            ;;
    esac
    
    info "Installing packages: ${packages[*]}"
    run_cmd ${PKG_INSTALL} "${packages[@]}" || die "Failed to install system packages"
    
    success "System dependencies installed"
}

install_docker() {
    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        info "Docker already installed: v${docker_version}"
        
        # Ensure Docker service is running
        if ! systemctl is-active --quiet docker; then
            info "Starting Docker service..."
            run_cmd systemctl start docker
            run_cmd systemctl enable docker
        fi
        return 0
    fi
    
    step "Installing Docker"
    
    case "${OS_ID}" in
        ubuntu|debian)
            # Remove old versions
            run_cmd apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            
            # Add Docker's official GPG key
            run_cmd mkdir -p /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | \
                run_cmd gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            run_cmd chmod a+r /etc/apt/keyrings/docker.gpg
            
            # Set up repository
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                https://download.docker.com/linux/${OS_ID} \
                $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
                run_cmd tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            run_cmd apt-get update -qq
            run_cmd apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        centos|rhel|rocky|almalinux)
            run_cmd ${PKG_INSTALL} yum-utils
            run_cmd yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            run_cmd ${PKG_INSTALL} docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
            
        fedora)
            run_cmd ${PKG_INSTALL} dnf-plugins-core
            run_cmd dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            run_cmd ${PKG_INSTALL} docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
    esac
    
    run_cmd systemctl start docker
    run_cmd systemctl enable docker
    
    success "Docker installed and started"
}

install_python() {
    step "Checking Python Installation"
    
    local python_cmd=""
    for cmd in python3.12 python3.11 python3.10 python3; do
        if command_exists "${cmd}"; then
            local ver
            ver=$("${cmd}" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if version_ge "${ver}" "${MIN_PYTHON_VERSION}"; then
                python_cmd="${cmd}"
                info "Found Python ${ver} at $(command -v ${cmd})"
                break
            fi
        fi
    done
    
    if [[ -z "${python_cmd}" ]]; then
        info "Installing Python ${MIN_PYTHON_VERSION}+..."
        
        case "${OS_ID}" in
            ubuntu|debian)
                # Add deadsnakes PPA for newer Python versions
                run_cmd apt-get install -y -qq software-properties-common
                run_cmd add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
                run_cmd apt-get update -qq
                run_cmd apt-get install -y -qq python3.11 python3.11-venv python3.11-dev python3-pip
                python_cmd="python3.11"
                ;;
            centos|rhel|rocky|almalinux)
                run_cmd ${PKG_INSTALL} python3.11 python3.11-devel python3.11-pip 2>/dev/null || \
                    run_cmd ${PKG_INSTALL} python3 python3-devel python3-pip
                python_cmd="python3.11"
                [[ ! -x "$(command -v ${python_cmd})" ]] && python_cmd="python3"
                ;;
            fedora)
                run_cmd ${PKG_INSTALL} python3 python3-devel python3-pip
                python_cmd="python3"
                ;;
        esac
    fi
    
    PYTHON_CMD="${python_cmd}"
    success "Python ready: ${PYTHON_CMD}"
}

install_nodejs() {
    step "Checking Node.js Installation"
    
    if command_exists node; then
        local node_version
        node_version=$(node --version | grep -oE '[0-9]+' | head -1)
        if [[ ${node_version} -ge ${MIN_NODE_VERSION} ]]; then
            info "Node.js already installed: $(node --version)"
            return 0
        else
            warning "Node.js version ${node_version} is too old. Need ${MIN_NODE_VERSION}+"
        fi
    fi
    
    info "Installing Node.js ${MIN_NODE_VERSION}..."
    
    # Use NodeSource repository
    curl -fsSL "https://deb.nodesource.com/setup_${MIN_NODE_VERSION}.x" | run_cmd bash -
    
    case "${OS_ID}" in
        ubuntu|debian)
            run_cmd apt-get install -y -qq nodejs
            ;;
        centos|rhel|rocky|almalinux|fedora)
            run_cmd ${PKG_INSTALL} nodejs
            ;;
    esac
    
    success "Node.js installed: $(node --version 2>/dev/null || echo 'check manually')"
}

install_rust() {
    if command_exists rustc; then
        info "Rust already installed: $(rustc --version)"
        return 0
    fi
    
    step "Installing Rust (required for tiktoken)"
    
    # Install Rust via rustup (non-interactive)
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        run_cmd sh -s -- -y --default-toolchain stable --profile minimal
    
    # Add to PATH for current session
    export PATH="${HOME}/.cargo/bin:${PATH}"
    
    success "Rust installed"
}

# ============================================================================
# User & Directory Setup
# ============================================================================

setup_service_user() {
    step "Setting Up Service User"
    
    if id "${SERVICE_USER}" &>/dev/null; then
        info "User '${SERVICE_USER}' already exists"
    else
        info "Creating user '${SERVICE_USER}'..."
        run_cmd useradd --system --shell /usr/sbin/nologin --home-dir "${INSTALL_DIR}" \
            --create-home --comment "DeepTutor Service" "${SERVICE_USER}" || \
            die "Failed to create service user"
        success "User '${SERVICE_USER}' created"
    fi
    
    # Add user to docker group if using Docker mode
    if [[ "${INSTALL_MODE}" == "docker" ]]; then
        run_cmd usermod -aG docker "${SERVICE_USER}" 2>/dev/null || true
    fi
}

setup_directories() {
    step "Setting Up Directory Structure"
    
    create_directory "${INSTALL_DIR}" "${SERVICE_USER}"
    create_directory "${INSTALL_DIR}/data/user" "${SERVICE_USER}"
    create_directory "${INSTALL_DIR}/data/knowledge_bases" "${SERVICE_USER}"
    create_directory "${INSTALL_DIR}/config" "${SERVICE_USER}"
    create_directory "${INSTALL_DIR}/logs" "${SERVICE_USER}"
    
    success "Directory structure ready at ${INSTALL_DIR}"
}

# ============================================================================
# Application Installation
# ============================================================================

clone_repository() {
    step "Cloning Repository"
    
    TEMP_DIR=$(mktemp -d)
    CLEANUP_NEEDED="true"
    
    info "Cloning from ${REPO_URL} (branch: ${GIT_BRANCH})..."
    
    run_cmd git clone --depth 1 --branch "${GIT_BRANCH}" "${REPO_URL}" "${TEMP_DIR}/repo" || \
        die "Failed to clone repository"
    
    # Copy files to installation directory
    info "Installing files to ${INSTALL_DIR}..."
    run_cmd cp -r "${TEMP_DIR}/repo/"* "${INSTALL_DIR}/" 2>/dev/null || true
    run_cmd cp -r "${TEMP_DIR}/repo/".* "${INSTALL_DIR}/" 2>/dev/null || true
    
    # Fix ownership
    run_cmd chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
    
    success "Repository cloned and installed"
}

copy_local_install() {
    # Alternative: If script is run from within the repo directory
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [[ -f "${script_dir}/requirements.txt" && -d "${script_dir}/src" ]]; then
        step "Installing from Local Directory"
        
        info "Copying from ${script_dir} to ${INSTALL_DIR}..."
        
        # Copy essential files and directories
        local items=(
            requirements.txt
            pyproject.toml
            src
            web
            config
            scripts
            .env.example
        )
        
        for item in "${items[@]}"; do
            if [[ -e "${script_dir}/${item}" ]]; then
                run_cmd cp -r "${script_dir}/${item}" "${INSTALL_DIR}/" || \
                    warning "Failed to copy ${item}"
            fi
        done
        
        run_cmd chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
        
        success "Local files installed"
        return 0
    fi
    
    return 1
}

setup_environment_file() {
    step "Configuring Environment"
    
    local env_dest="${INSTALL_DIR}/.env"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
            debug "Would copy environment file from ${ENV_FILE}"
        else
            debug "Would create minimal .env file at ${env_dest}"
        fi
        debug "Would run: chown ${SERVICE_USER}:${SERVICE_USER} ${env_dest}"
        debug "Would run: chmod 600 ${env_dest}"
        success "Environment would be configured at ${env_dest}"
        return 0
    fi
    
    if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
        info "Copying environment file from ${ENV_FILE}..."
        cp "${ENV_FILE}" "${env_dest}" || die "Failed to copy environment file"
    elif [[ -f "${INSTALL_DIR}/.env.example" ]]; then
        if [[ ! -f "${env_dest}" ]]; then
            info "Creating .env from .env.example..."
            cp "${INSTALL_DIR}/.env.example" "${env_dest}" || die "Failed to copy .env.example"
            warning "Please edit ${env_dest} with your API keys!"
        else
            info "Using existing .env file"
        fi
    else
        # Create minimal .env file
        info "Creating minimal .env file..."
        cat > "${env_dest}" << EOF
# DeepTutor Configuration
# Generated by install_pro.sh on $(date)

# Server Ports
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}

# LLM Configuration (REQUIRED - Update these values!)
LLM_BINDING=openai
LLM_MODEL=gpt-4o
LLM_API_KEY=sk-your-api-key-here
LLM_HOST=https://api.openai.com/v1

# Embedding Configuration (REQUIRED - Update these values!)
EMBEDDING_BINDING=openai
EMBEDDING_MODEL=text-embedding-3-small
EMBEDDING_API_KEY=sk-your-api-key-here
EMBEDDING_HOST=https://api.openai.com/v1
EMBEDDING_DIMENSION=3072
EOF
        warning "Created ${env_dest} - YOU MUST UPDATE API KEYS!"
    fi
    
    # Update ports in .env file
    if [[ -f "${env_dest}" ]]; then
        sed -i "s/^BACKEND_PORT=.*/BACKEND_PORT=${BACKEND_PORT}/" "${env_dest}"
        sed -i "s/^FRONTEND_PORT=.*/FRONTEND_PORT=${FRONTEND_PORT}/" "${env_dest}"
    fi
    
    # Secure the environment file
    chown "${SERVICE_USER}:${SERVICE_USER}" "${env_dest}" 2>/dev/null || true
    chmod 600 "${env_dest}" || true
    
    success "Environment configured at ${env_dest}"
}

install_python_deps() {
    step "Installing Python Dependencies"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        debug "Would create Python virtual environment at ${INSTALL_DIR}/venv"
        debug "Would run: pip install --upgrade pip wheel setuptools"
        debug "Would run: pip install uv"
        debug "Would run: pip install -r requirements.txt"
        success "Python dependencies would be installed"
        return 0
    fi
    
    cd "${INSTALL_DIR}" || die "Cannot access ${INSTALL_DIR}"
    
    # Create virtual environment
    info "Creating Python virtual environment..."
    run_cmd "${PYTHON_CMD}" -m venv "${INSTALL_DIR}/venv" || \
        die "Failed to create virtual environment"
    
    # Activate and install
    source "${INSTALL_DIR}/venv/bin/activate"
    
    info "Upgrading pip..."
    run_cmd pip install --upgrade pip wheel setuptools
    
    # Install uv for faster dependency resolution
    info "Installing uv for faster dependency resolution..."
    run_cmd pip install uv 2>/dev/null || warning "uv not available, using pip"
    
    info "Installing Python dependencies (this may take several minutes)..."
    
    if command_exists uv; then
        run_cmd uv pip install -r requirements.txt || \
            run_cmd pip install -r requirements.txt
    else
        run_cmd pip install -r requirements.txt
    fi
    
    deactivate
    
    # Fix ownership
    run_cmd chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/venv"
    
    success "Python dependencies installed"
}

install_nodejs_deps() {
    step "Installing Node.js Dependencies"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        debug "Would run: npm install --legacy-peer-deps"
        debug "Would run: npm run build"
        success "Node.js dependencies would be installed"
        return 0
    fi
    
    cd "${INSTALL_DIR}/web" || die "Cannot access ${INSTALL_DIR}/web"
    
    info "Installing frontend dependencies..."
    npm install --legacy-peer-deps || die "Failed to install Node.js dependencies"
    
    info "Building frontend for production..."
    
    # Set API base URL for build
    export NEXT_PUBLIC_API_BASE="http://localhost:${BACKEND_PORT}"
    npm run build || warning "Frontend build had issues (may work in dev mode)"
    
    # Fix ownership
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/web" 2>/dev/null || true
    
    success "Node.js dependencies installed"
}

# ============================================================================
# Docker Installation
# ============================================================================

install_docker_mode() {
    step "Docker Installation Mode"
    
    install_docker
    
    # Create docker-compose override for custom configuration
    local compose_file="${INSTALL_DIR}/docker-compose.override.yml"
    
    info "Creating docker-compose override..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        debug "Would create docker-compose override at ${compose_file}"
        debug "Would run: chown ${SERVICE_USER}:${SERVICE_USER} ${compose_file}"
        success "Docker configuration ready (dry-run)"
        return 0
    fi
    
    cat > "${compose_file}" << EOF
# Auto-generated by install_pro.sh
# Custom configuration for DeepTutor

services:
  deeptutor:
    ports:
      - "${BACKEND_PORT}:${BACKEND_PORT}"
      - "${FRONTEND_PORT}:${FRONTEND_PORT}"
    environment:
      - BACKEND_PORT=${BACKEND_PORT}
      - FRONTEND_PORT=${FRONTEND_PORT}
EOF
    
    chown "${SERVICE_USER}:${SERVICE_USER}" "${compose_file}" 2>/dev/null || true
    
    success "Docker configuration ready"
}

# ============================================================================
# Native Installation
# ============================================================================

install_native_mode() {
    step "Native Installation Mode"
    
    install_python
    install_nodejs
    install_rust
    
    install_python_deps
    install_nodejs_deps
    
    success "Native installation complete"
}

# ============================================================================
# Systemd Service Configuration
# ============================================================================

create_systemd_service_docker() {
    step "Creating Systemd Service (Docker)"
    
    local service_file="/etc/systemd/system/deeptutor.service"
    
    info "Creating systemd service at ${service_file}..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        debug "Would create systemd service file at ${service_file}"
        debug "Would run: chmod 644 ${service_file}"
        debug "Would run: systemctl daemon-reload"
        success "Systemd service would be created"
        return 0
    fi
    
    cat > "${service_file}" << EOF
[Unit]
Description=DeepTutor AI Learning Assistant (Docker)
Documentation=https://github.com/HKUDS/DeepTutor
After=network.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/.env

# Start container(s)
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart

# Restart policy
Restart=on-failure
RestartSec=10

# Security hardening
NoNewPrivileges=false
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}/data ${INSTALL_DIR}/logs
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    run_cmd chmod 644 "${service_file}"
    run_cmd systemctl daemon-reload
    
    success "Systemd service created"
}

create_systemd_service_native() {
    step "Creating Systemd Services (Native)"
    
    # Backend service
    local backend_service="/etc/systemd/system/deeptutor-backend.service"
    local frontend_service="/etc/systemd/system/deeptutor-frontend.service"
    local target_file="/etc/systemd/system/deeptutor.target"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        debug "Would create backend service at ${backend_service}"
        debug "Would create frontend service at ${frontend_service}"
        debug "Would create target at ${target_file}"
        debug "Would run: chmod 644 ${backend_service} ${frontend_service} ${target_file}"
        debug "Would run: systemctl daemon-reload"
        success "Systemd services would be created"
        return 0
    fi
    
    cat > "${backend_service}" << EOF
[Unit]
Description=DeepTutor Backend API (FastAPI)
Documentation=https://github.com/HKUDS/DeepTutor
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONPATH=${INSTALL_DIR}"
Environment="PYTHONUNBUFFERED=1"

ExecStart=${INSTALL_DIR}/venv/bin/python -m uvicorn src.api.main:app \\
    --host 0.0.0.0 \\
    --port ${BACKEND_PORT} \\
    --workers 1

# Restart policy
Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}/data ${INSTALL_DIR}/logs
PrivateTmp=true
ProtectHome=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=deeptutor-backend

[Install]
WantedBy=multi-user.target
EOF
    
    # Frontend service (variable already declared at top)
    cat > "${frontend_service}" << EOF
[Unit]
Description=DeepTutor Frontend (Next.js)
Documentation=https://github.com/HKUDS/DeepTutor
After=network.target deeptutor-backend.service
Wants=deeptutor-backend.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}/web
EnvironmentFile=${INSTALL_DIR}/.env
Environment="NODE_ENV=production"
Environment="NEXT_PUBLIC_API_BASE=http://localhost:${BACKEND_PORT}"
Environment="PORT=${FRONTEND_PORT}"

ExecStart=/usr/bin/npm start -- -p ${FRONTEND_PORT}

# Restart policy
Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}/web/.next
PrivateTmp=true
ProtectHome=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=deeptutor-frontend

[Install]
WantedBy=multi-user.target
EOF
    
    # Target for both services (variable already declared at top)
    cat > "${target_file}" << EOF
[Unit]
Description=DeepTutor Complete Stack
Documentation=https://github.com/HKUDS/DeepTutor
Requires=deeptutor-backend.service deeptutor-frontend.service
After=deeptutor-backend.service deeptutor-frontend.service

[Install]
WantedBy=multi-user.target
EOF
    
    run_cmd chmod 644 "${backend_service}" "${frontend_service}" "${target_file}"
    run_cmd systemctl daemon-reload
    
    success "Systemd services created"
}

enable_and_start_services() {
    if [[ "${START_SERVICES}" != "true" ]]; then
        info "Skipping service start (--no-start specified)"
        return 0
    fi
    
    step "Starting Services"
    
    if [[ "${INSTALL_MODE}" == "docker" ]]; then
        run_cmd systemctl enable deeptutor
        run_cmd systemctl start deeptutor
        
        info "Waiting for containers to start..."
        sleep 10
        
        if run_cmd docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps | grep -q "running"; then
            success "Docker containers are running"
        else
            warning "Containers may not be fully started yet"
        fi
    else
        run_cmd systemctl enable deeptutor-backend deeptutor-frontend deeptutor.target
        run_cmd systemctl start deeptutor.target
        
        info "Waiting for services to start..."
        sleep 5
        
        if systemctl is-active --quiet deeptutor-backend; then
            success "Backend service is running"
        else
            warning "Backend service may have issues. Check: journalctl -u deeptutor-backend"
        fi
        
        if systemctl is-active --quiet deeptutor-frontend; then
            success "Frontend service is running"
        else
            warning "Frontend service may have issues. Check: journalctl -u deeptutor-frontend"
        fi
    fi
}

# ============================================================================
# Firewall Configuration
# ============================================================================

configure_firewall() {
    step "Configuring Firewall"
    
    if command_exists ufw; then
        info "Configuring UFW firewall..."
        run_cmd ufw allow "${BACKEND_PORT}/tcp" comment "DeepTutor Backend"
        run_cmd ufw allow "${FRONTEND_PORT}/tcp" comment "DeepTutor Frontend"
        success "UFW rules added"
    elif command_exists firewall-cmd; then
        info "Configuring firewalld..."
        run_cmd firewall-cmd --permanent --add-port="${BACKEND_PORT}/tcp"
        run_cmd firewall-cmd --permanent --add-port="${FRONTEND_PORT}/tcp"
        run_cmd firewall-cmd --reload
        success "Firewalld rules added"
    else
        info "No firewall detected. Ensure ports ${BACKEND_PORT} and ${FRONTEND_PORT} are accessible."
    fi
}

# ============================================================================
# Post-Installation Summary
# ============================================================================

print_summary() {
    local env_file="${INSTALL_DIR}/.env"
    
    echo
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  DeepTutor Installation Complete! 🎉${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${BOLD}Installation Details:${NC}"
    echo -e "  • Mode:            ${CYAN}${INSTALL_MODE}${NC}"
    echo -e "  • Install Dir:     ${CYAN}${INSTALL_DIR}${NC}"
    echo -e "  • Backend Port:    ${CYAN}${BACKEND_PORT}${NC}"
    echo -e "  • Frontend Port:   ${CYAN}${FRONTEND_PORT}${NC}"
    echo -e "  • Service User:    ${CYAN}${SERVICE_USER}${NC}"
    echo
    echo -e "${BOLD}Access URLs:${NC}"
    echo -e "  • Frontend:        ${CYAN}http://localhost:${FRONTEND_PORT}${NC}"
    echo -e "  • API Docs:        ${CYAN}http://localhost:${BACKEND_PORT}/docs${NC}"
    echo
    echo -e "${BOLD}Service Management:${NC}"
    if [[ "${INSTALL_MODE}" == "docker" ]]; then
        echo -e "  • Start:           ${CYAN}sudo systemctl start deeptutor${NC}"
        echo -e "  • Stop:            ${CYAN}sudo systemctl stop deeptutor${NC}"
        echo -e "  • Status:          ${CYAN}sudo systemctl status deeptutor${NC}"
        echo -e "  • Logs:            ${CYAN}cd ${INSTALL_DIR} && docker compose logs -f${NC}"
    else
        echo -e "  • Start:           ${CYAN}sudo systemctl start deeptutor.target${NC}"
        echo -e "  • Stop:            ${CYAN}sudo systemctl stop deeptutor.target${NC}"
        echo -e "  • Status:          ${CYAN}sudo systemctl status deeptutor-*${NC}"
        echo -e "  • Backend Logs:    ${CYAN}journalctl -u deeptutor-backend -f${NC}"
        echo -e "  • Frontend Logs:   ${CYAN}journalctl -u deeptutor-frontend -f${NC}"
    fi
    echo
    
    # Check if API keys need to be configured
    if grep -q "sk-your-api-key-here\|sk-xxx" "${env_file}" 2>/dev/null; then
        echo -e "${BOLD}${YELLOW}⚠️  IMPORTANT: API Keys Required!${NC}"
        echo -e "   Edit ${CYAN}${env_file}${NC} with your API keys:"
        echo -e "   ${CYAN}sudo nano ${env_file}${NC}"
        echo
    fi
    
    echo -e "${BOLD}Manual Steps Required:${NC}"
    echo -e "  1. Configure API keys in ${CYAN}${env_file}${NC}"
    echo -e "  2. (Optional) Set up SSL/TLS with a reverse proxy (nginx/Caddy)"
    echo -e "  3. (Optional) Configure DNS for your domain"
    echo -e "  4. (Optional) Set NEXT_PUBLIC_API_BASE_EXTERNAL for remote access"
    echo
    echo -e "${BOLD}Documentation:${NC} ${CYAN}https://github.com/HKUDS/DeepTutor${NC}"
    echo
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode)
                INSTALL_MODE="$2"
                if [[ "${INSTALL_MODE}" != "docker" && "${INSTALL_MODE}" != "native" ]]; then
                    die "Invalid mode: ${INSTALL_MODE}. Use 'docker' or 'native'"
                fi
                shift 2
                ;;
            -d|--install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -b|--backend-port)
                BACKEND_PORT="$2"
                if ! [[ "${BACKEND_PORT}" =~ ^[0-9]+$ ]] || [[ "${BACKEND_PORT}" -lt 1 ]] || [[ "${BACKEND_PORT}" -gt 65535 ]]; then
                    die "Invalid backend port: ${BACKEND_PORT}"
                fi
                shift 2
                ;;
            -f|--frontend-port)
                FRONTEND_PORT="$2"
                if ! [[ "${FRONTEND_PORT}" =~ ^[0-9]+$ ]] || [[ "${FRONTEND_PORT}" -lt 1 ]] || [[ "${FRONTEND_PORT}" -gt 65535 ]]; then
                    die "Invalid frontend port: ${FRONTEND_PORT}"
                fi
                shift 2
                ;;
            -e|--env-file)
                ENV_FILE="$2"
                if [[ ! -f "${ENV_FILE}" ]]; then
                    die "Environment file not found: ${ENV_FILE}"
                fi
                shift 2
                ;;
            -u|--user)
                SERVICE_USER="$2"
                shift 2
                ;;
            -n|--no-start)
                START_SERVICES="false"
                shift
                ;;
            -r|--repo-url)
                REPO_URL="$2"
                shift 2
                ;;
            -t|--branch)
                GIT_BRANCH="$2"
                shift 2
                ;;
            --skip-deps)
                SKIP_DEPS="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                die "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

# ============================================================================
# Main Installation Flow
# ============================================================================

main() {
    parse_arguments "$@"
    
    echo
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  DeepTutor Production Installation Script v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        warning "DRY RUN MODE - No changes will be made"
        echo
    fi
    
    # System checks
    step "System Validation"
    check_root
    detect_os
    check_architecture
    check_systemd
    check_memory
    check_disk_space
    
    # Install system dependencies
    install_system_deps
    
    # Set up user and directories
    setup_service_user
    setup_directories
    
    # Clone/copy application
    if ! copy_local_install; then
        clone_repository
    fi
    
    # Set up environment
    setup_environment_file
    
    # Mode-specific installation
    if [[ "${INSTALL_MODE}" == "docker" ]]; then
        install_docker_mode
        create_systemd_service_docker
    else
        install_native_mode
        create_systemd_service_native
    fi
    
    # Configure firewall
    configure_firewall
    
    # Start services
    enable_and_start_services
    
    # Print summary
    print_summary
}

# ============================================================================
# Entry Point
# ============================================================================

main "$@"
