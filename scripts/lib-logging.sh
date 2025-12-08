#!/usr/bin/env bash
#
# lib-logging.sh - Shared logging utilities for Fluidity scripts
#
# Provides consistent logging functions across all deployment and build scripts.
# Supports color-coded output for headers, info messages, and errors.
#
# Usage in other scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib-logging.sh"
#   log_header "My Script"
#   log_info "This is an info message"
#   log_debug "This only shows with --debug"
#
# Logging Levels:
#   - log_header: Major section header (PALE_BLUE)
#   - log_minor: Minor section header (PALE_YELLOW)
#   - log_substep: Subsection (PALE_GREEN)
#   - log_info: High-level flow information
#   - log_debug: Detailed info (only with --debug or DEBUG=true)
#   - log_warn: Warning messages
#   - log_success: Success messages with checkmark
#   - log_error_start/end: Error blocks
#

# Color definitions (light pastel palette)
PALE_BLUE='\033[38;5;153m'       # Light pastel blue (major headers)
PALE_YELLOW='\033[38;5;229m'     # Light pastel yellow (minor headers)
PALE_GREEN='\033[38;5;193m'      # Light pastel green (sub-headers)
WHITE='\033[1;37m'               # Standard white (info logs)
RED='\033[0;31m'                 # Standard red (errors)
RESET='\033[0m'

# Export DEBUG flag if not already set
DEBUG="${DEBUG:-false}"

# ============================================================================
# HEADER & SECTION LOGGING
# ============================================================================

log_header() {
    echo ""
    echo ""
    echo -e "${PALE_BLUE}================================================================================${RESET}"
    echo -e "${PALE_BLUE}$*${RESET}"
    echo -e "${PALE_BLUE}================================================================================${RESET}"
}

log_minor() {
    echo ""
    echo ""
    echo -e "${PALE_YELLOW}$*${RESET}"
    echo -e "${PALE_YELLOW}================================================================================${RESET}"
}

log_section() {
    echo ""
    echo ""
    echo -e "${PALE_YELLOW}$*${RESET}"
    echo -e "${PALE_YELLOW}================================================================================${RESET}"
}

log_substep() {
    echo ""
    echo ""
    echo -e "${PALE_GREEN}$*${RESET}"
    echo -e "${PALE_GREEN}--------------------------------------------------------------------------------${RESET}"
}

# ============================================================================
# INFO & DEBUG LOGGING
# ============================================================================

log_info() {
    echo "[INFO] $*"
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_success() {
    echo "✓ $*"
}

# ============================================================================
# ERROR LOGGING
# ============================================================================

log_error_start() {
    echo ""
    echo -e "${RED}================================================================================${RESET}"
    echo -e "${RED}ERROR${RESET}"
    echo -e "${RED}================================================================================${RESET}"
}

log_error_end() {
    echo -e "${RED}================================================================================${RESET}"
    echo ""
}

log_error() {
    echo -e "${RED}[ERROR] $*${RESET}" >&2
}
