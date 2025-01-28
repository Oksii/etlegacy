#!/bin/bash

###############################################################################
#
# ETLegacy Server Setup Script
# Version: 1.0.0
# Last Updated: 2025-01-18
# Author: Oksii
#
# Description:
# Automated installation and configuration script for ETLegacy game servers
# using Docker containers. Sets up multiple server instances, configures maps,
# and manages all necessary dependencies.
#
# License:
# MIT License
# Copyright (c) 2025 Oksii
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# Tested On:
# - Ubuntu 24.10 (AMD64/ARM64)
# - Ubuntu 24.04 LTS (AMD64/ARM64)
# - Ubuntu 22.04 LTS (AMD64/ARM64)
# - Ubuntu 22.04 LTS Minimal (AMD64/ARM64)
# - Debian 11 Bullseye (AMD64/ARM64)
# - Debian 12 Bookworm (AMD64/ARM64)
# - CentOS 9 Stream (AMD64/ARM64)
# - Amazon Linux 2023 (AMD64/ARM64)
#
# Features:
# - Multi-server instance support
# - Automated Docker installation and configuration
# - Map downloads and management
# - Match statistic tracking and submission
# - Automatic updates via Watchtower
# - Built-in map download webserver
# - User management and security
# - Includes helper script to manage servers and interact with docker
#
# Requirements:
# - Root access or sudo privileges
# - Internet connection
# - Minimum 1GB RAM
# - 2GB free disk space
#
# Notes:
# - Full multi-architecture support (AMD64/ARM64)
# - DO NOT use on CentOS 10 (known compatibility issues)
# - Requires port forwarding for server ports (default: 27960+)
# - Uses official Docker installation method
# - Creates required user and group permissions
# - All Docker images are multi-arch compatible
#
###############################################################################

# Global variables
SELECTED_USER=""
INSTANCES=1
INSTALL_DIR=""

# Set current user handling both sudo and non-sudo cases
if [ -n "${SUDO_USER-}" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$USER"
fi

SETTINGS_FILE="settings.env"
DEFAULT_MAPS="adlernest braundorf_b4 bremen_b3 decay_sw erdenberg_t2 et_brewdog_b6 et_ice et_operation_b7 etl_adlernest_v4 etl_frostbite_v17 etl_ice_v12 etl_sp_delivery_v5 frostbite karsiah_te2 missile_b3 supply_sp sw_goldrush_te te_escape2_fixed3 te_valhalla reactor_final"

DEBUG=${DEBUG:-0}

# Color definitions for pretty output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# Get terminal width
TERM_WIDTH=$(tput cols)

strip_ansi() {
    echo "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

print_text() {
    local text="$1"
    local center=${2:-false}
    local width=${3:-$TERM_WIDTH}
    
    if [ "$center" = true ]; then
        local visible_length=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
        local padding=$(( (width - visible_length + 1) / 2 ))
        printf "%${padding}s%b%${padding}s\n" "" "$text" ""
    else
        printf "%b\n" "$text"
    fi
}


show_header() {
    local style=${1:-"normal"}
    
    clear
    echo
    
    local border="════════════════════════════════════════════"
    local title="            ETLegacy Server Setup           "
    
    printf "%b" "${CYAN}"
    echo "╔${border}╗"
    echo "║${title}║"
    echo "╚${border}╝"
    printf "%b" "${NC}"
    
    echo
    log "" "Date (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
    log "" "User: $USER"
    echo
}

print_section_header() {
    local title="$1"
    local subtitle="${2:-}"
    local color=${3:-$PURPLE}
    
    local title_length=${#title}
    local subtitle_length=0
    
    if [ -n "$subtitle" ]; then
        subtitle_length=$((${#subtitle} + 4))
    fi
    
    local max_length=$(( title_length > subtitle_length ? title_length : subtitle_length ))
    max_length=$((max_length + 4))
    
    # Create divider of appropriate length
    local divider=$(printf '━%.0s' $(seq 1 $max_length))
    
    echo
    printf "%b" "$color"
    echo "$divider"
    echo "  ${title}"
    if [ -n "$subtitle" ]; then
        printf "%b" "$BLUE"
        echo "  ℹ  ${subtitle}"
        printf "%b" "$color"
    fi
    echo "$divider"
    printf "%b" "$NC"
    echo
    echo
}

log() {
    local type=$1
    local message=$2
    local prefix=""
    local color=$NC
    
    case $type in
        "success") prefix="✔"; color=$GREEN ;;
        "warning") prefix="⚠"; color=$YELLOW ;;
        "info")    prefix="ℹ"; color=$BLUE ;;
        "error")   prefix="✖"; color=$RED ;;
        "prompt")  prefix="→"; color=$CYAN ;; 
        *)         prefix=" "; color=$NC ;;
    esac
    
    printf "%b%s  %s%b\n" "$color" "$prefix" "$message" "$NC"
}


set -euo pipefail
trap 'handle_error ${LINENO} $?' ERR
trap 'echo -e "\nScript interrupted by user" >&2; exit 1' INT

handle_error() {
    local line_no=$1
    local error_code=$2
    log "error" "Error occurred on line $line_no (Exit code: $error_code)"
    if [ "$DEBUG" = "1" ]; then
        log "info" "Stack trace:"
        local frame=0
        while caller $frame; do
            ((frame++))
        done
    fi
}

get_os_type() {
    if command -v lsb_release >/dev/null 2>&1; then
        os_id=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    elif [ -f /etc/os-release ]; then
        os_id=$(. /etc/os-release && echo "$ID" | tr '[:upper:]' '[:lower:]')
    else
        log "error" "Cannot determine OS type"
        exit 1
    fi
    echo "$os_id"
}

# Initialize settings storage and files
init_settings_manager() {
    local install_dir="$1"
    local selected_user="$2"
    
    # Create settings file if it doesn't exist
    if [ ! -f "$install_dir/settings.env" ]; then
        touch "$install_dir/settings.env"
        chown "$selected_user:$selected_user" "$install_dir/settings.env"
    fi
    
    # Initialize associative arrays for settings
    declare -g -A GLOBAL_SETTINGS=()
    declare -g -A INSTANCE_SETTINGS=()
    declare -g -A REQUIRED_SETTINGS=()
    
    # Store core version setting
    store_setting "Core" "VERSION" "stable"
}

# Store a setting with optional category
store_setting() {
    local category="$1"
    local key="$2"
    local value="$3"
    local is_global="${4:-false}"
    
    # Sanitize the value
    value=$(echo "$value" | sed 's/"/\\"/g')
    
    if [ "$is_global" = "true" ]; then
        GLOBAL_SETTINGS["$key"]="$value"
    fi
    
    # Add category comment if it's the first setting in this category
    if ! grep -q "# $category" "$SETTINGS_FILE" 2>/dev/null; then
        echo -e "\n# $category" >> "$SETTINGS_FILE"
    fi
    
    # Update or add setting in file
    if grep -q "^$key=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$value|" "$SETTINGS_FILE"
    else
        echo "$key=$value" >> "$SETTINGS_FILE"
    fi
}

# Store an instance-specific setting
store_server_setting() {
    local instance="$1"
    local key="$2"
    local value="$3"
    
    # Format the instance-specific key
    local instance_key="SERVER${instance}_${key}"
    
    # Sanitize the value
    value=$(echo "$value" | sed 's/"/\\"/g')
    
    INSTANCE_SETTINGS["$instance_key"]="$value"
    
    # Update or add setting in file
    if grep -q "^$instance_key=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^$instance_key=.*|$instance_key=$value|" "$SETTINGS_FILE"
    else
        echo "$instance_key=$value" >> "$SETTINGS_FILE"
    fi
}

review_settings() {
    show_header
    print_section_header "Settings Review"
    
    log "prompt" "Current Settings Configuration:"
    echo
    
    if [ -f "$SETTINGS_FILE" ]; then
        local current_category=""
        while IFS= read -r line; do
            # Handle comment lines (categories)
            if [[ "$line" =~ ^#[[:space:]](.+)$ ]]; then
                current_category="${BASH_REMATCH[1]}"
                echo -e "\n${BLUE}${current_category}:${NC}"
            # Handle actual settings
            elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                echo -e "  ${BOLD}${key}${NC}: $value"
            fi
        done < "$SETTINGS_FILE"
        
        echo -e "\nPress any key to continue..."
        read -n 1
    else
        log "error" "Settings file not found!"
        sleep 2
    fi
}

# Reorganize settings file - we like things organized
reorganize_settings_file() {
    local temp_file=$(mktemp)
    
    # Add core settings first
    cat > "$temp_file" << EOL
# Core
VERSION=stable

EOL

    echo "# Volumes" >> "$temp_file"
    grep "^MAPSDIR=" "$SETTINGS_FILE" >> "$temp_file" || true
    grep "^LOGS=" "$SETTINGS_FILE" >> "$temp_file" || true
    
    echo -e "\n# Map Settings" >> "$temp_file"
    grep "^MAPS=" "$SETTINGS_FILE" >> "$temp_file" || true
    
    echo -e "\n# Additional Settings" >> "$temp_file"
    # Find all global settings that don't belong to other categories
    grep -v "^SERVER[0-9]\+_\|^VERSION=\|^MAPSDIR=\|^LOGS=\|^MAPS=\|^STATS_" "$SETTINGS_FILE" | \
    while read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^#.* ]]; then
            echo "$line" >> "$temp_file"
        fi
    done
    
    echo -e "\n# Stats Configuration" >> "$temp_file"
    grep "^STATS_" "$SETTINGS_FILE" >> "$temp_file" || true

    # Group server settings by instance
    while read -r instance; do
        if [ -n "$instance" ]; then
            # Get hostname for this instance
            hostname=$(grep "^${instance}_HOSTNAME=" "$SETTINGS_FILE" | cut -d'=' -f2)
            [ -z "$hostname" ] && hostname="ETL-Server ${instance#SERVER}"

            echo -e "\n# Server: $hostname" >> "$temp_file"
            grep "^${instance}_" "$SETTINGS_FILE" | sort >> "$temp_file"
        fi
    done < <(grep "^SERVER[0-9]\+_" "$SETTINGS_FILE" | cut -d'_' -f1 | sort -u)

    mv "$temp_file" "$SETTINGS_FILE"
}

setup_installation_directory() {
    local current_user="$1"
    local user_home="$(getent passwd "$current_user" | cut -d: -f6)"
    local default_dir="$user_home/etlserver"
    local install_dir=""
    
    show_header
    print_section_header "Installation Directory Setup"
    
    log "prompt" "Please specify where to install ETLegacy Server files."
    log "prompt" "This directory will contain:"
    log "" "  • Server configuration files"
    log "" "  • Map files"
    log "" "  • Log files"
    log "" "  • Docker compose configuration"
    log "" "  • 'etl-server' helper tool to manage your servers"
    echo
    echo
    log "prompt" "Current User's Login: $current_user"
    log "prompt" "User's Home Directory: $user_home\n"
    echo
    echo
    read -p "Install to default path: [default: $default_dir] (Y/n): " USE_DEFAULT
    
    if [[ ! $USE_DEFAULT =~ ^[Nn]$ ]]; then
        install_dir="$default_dir"
    else
        show_header
        print_section_header "Custom Installation Path"
        log "warning" "Enter the full path where you want to install ETLegacy Server:"
        while true; do
            read -p "> " install_dir
            
            # If empty, use default
            if [ -z "$install_dir" ]; then
                install_dir="$default_dir"
                break
            fi
            
            # Validate the path
            if [[ "$install_dir" != /* ]]; then
                log "warning" "Please provide an absolute path (starting with /)"
                continue
            fi
            
            break
        done
    fi
    
    if [ -d "$install_dir" ] && [ "$(ls -A "$install_dir" 2>/dev/null)" ]; then
        log "warning" "Directory exists and is not empty"
        read -p "Do you want to use this directory anyway? (y/N): " USE_EXISTING
        if [[ ! $USE_EXISTING =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    if setup_directory "$install_dir" "$current_user"; then
        show_header
        log "success" "Installation directory setup complete: $install_dir"
        sleep 1
        INSTALL_DIR="$install_dir"
        export INSTALL_DIR
        return 0
    else
        log "error" "Failed to setup installation directory"
        return 1
    fi
}

setup_directory() {
    local dir="$1"
    local owner="$2"
    local perms="${3:-755}"
    
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            log "error" "Failed to create directory: $dir"
            return 1
        }
    fi
    chmod "$perms" "$dir" || {
        log "error" "Failed to set permissions on $dir"
        return 1
    }
    chown -R "$owner:$owner" "$dir" || {
        log "error" "Failed to set ownership of $dir to $owner"
        return 1
    }
    return 0
}

check_pk3() {
    local mapname=$1
    if [[ $mapname != *.pk3 ]]; then
        echo "${mapname}.pk3"
    else
        echo "$mapname"
    fi
}

check_system() {
    local os_type
    local os_version
    
    # Try to get OS info from /etc/os-release first
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_type="$ID"
        os_version="$VERSION_ID"
    # Fallback to lsb_release if available
    elif command -v lsb_release >/dev/null 2>&1; then
        os_type=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        os_version=$(lsb_release -sr)
    else
        log "error" "Cannot determine OS type"
        exit 1
    fi

    case "$os_type" in
        ubuntu|debian)
            log "success" "System compatibility check passed ($os_type $os_version)"
            ;;
        centos|rhel|amzn|rocky|almalinux)
            # Install EPEL repository first if needed
            if [ ! -f /etc/yum.repos.d/epel.repo ]; then
                log "info" "Installing EPEL repository..."
                yum install -y epel-release &>/dev/null
            fi
            log "success" "System compatibility check passed ($os_type $os_version)"
            ;;
        *)
            log "error" "Unsupported operating system: $os_type"
            log "error" "This script supports: Ubuntu, Debian, CentOS, RHEL, Amazon Linux"
            exit 1
            ;;
    esac
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        if ! command -v sudo &>/dev/null; then
            log "error" "This script must be run as root or with sudo."
            exit 1
        fi
        if ! sudo -v &>/dev/null; then
            log "error" "This script requires sudo privileges."
            exit 1
        fi
    fi
}

install_requirements() {
    show_header
    
    local os_type=$(get_os_type)
    print_section_header "Installing Required Packages" "Detected OS: $os_type"
    
    # Check if we're root, if not use sudo
    local SUDO=""
    if [ "$EUID" -ne 0 ]; then 
        SUDO="sudo"
    fi
    
    case "$os_type" in
        ubuntu|debian)
            local packages=(
                curl
                wget
                parallel
                lsb-release
                gnupg
                ca-certificates
                apt-transport-https
            )
            
            echo -n "Updating package lists... "
            if $SUDO apt-get update &>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
                return 1
            fi
            
            for package in "${packages[@]}"; do
                echo -n "Installing $package... "
                if $SUDO apt-get install -y "$package" &>/dev/null; then
                    echo -e "${GREEN}OK${NC}"
                else
                    echo -e "${RED}FAILED${NC}"
                    log "error" "Failed to install $package"
                    return 1
                fi
            done
            ;;
            

        centos|rhel|amzn|rocky|almalinux)
            # Update package lists for yum-based systems
            echo -n "Updating package lists... "
            if $SUDO yum check-update &>/dev/null || [ $? -eq 100 ]; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
                return 1
            fi

            # Install EPEL
            if [ "$os_type" != "amzn" ]; then
                echo -n "Installing EPEL repository... "
                if $SUDO yum install -y epel-release &>/dev/null; then
                    echo -e "${GREEN}OK${NC}"
                else
                    echo -e "${RED}FAILED${NC}"
                    return 1
                fi
            fi

            local packages=(
                curl
                wget
                parallel
                yum-utils
                ca-certificates
            )
            
            # Install packages
            for package in "${packages[@]}"; do
                echo -n "Installing $package... "
                if $SUDO yum install -y "$package" &>/dev/null; then
                    echo -e "${GREEN}OK${NC}"
                else
                    echo -e "${RED}FAILED${NC}"
                    log "error" "Failed to install $package"
                    return 1
                fi
            done
            ;;
            
        *)
            log "error" "Unsupported operating system: $os_type"
            log "error" "This script supports: Ubuntu, Debian, CentOS, RHEL, Amazon Linux"
            return 1
            ;;
    esac

    log "success" "All required packages installed successfully!"
    sleep 2
    return 0
}

setup_user() {
    show_header
    print_section_header "User Account Setup"
    
    SELECTED_USER=""
    local default_server_user="etlserver"
    local current_user
    local real_user

    if [ -n "${SUDO_USER-}" ]; then
        real_user="$SUDO_USER"
    elif [ "$USER" != "root" ]; then
        real_user="$USER"
    else
        real_user=$(who am i | awk '{print $1}')
        # If still empty (e.g., running in a container), default to root
        [ -z "$real_user" ] && real_user="root"
    fi
    
    current_user="$real_user"
    
    # Check if current user is a regular user (UID >= 1000)
    local current_uid
    if [ "$current_user" = "root" ]; then
        current_uid=0
    else
        current_uid=$(id -u "$current_user")
    fi
    
    local suggested_option="2"  # Default to creating new user
    
    if [ "$current_uid" -ge 1000 ]; then
        suggested_option="1"  # Suggest using current user if it's a regular user
    fi

    log "prompt" "Choose a user account for running the ETLegacy servers:"
    echo
    
    # Options with colors but minimal indentation
    log "info" "  1. Use current user ($current_user)"
    log "info" "  2. Create new dedicated server user"
    log "info" "  3. Use different existing system user"
    echo
    
    # Suggestion with no indentation
    log "prompt" "Suggestion: Option $suggested_option"
    echo
    
    while true; do
        read -p "Select option (1-3) [default: $suggested_option]: " USER_OPTION
        USER_OPTION=${USER_OPTION:-$suggested_option}
        
        case $USER_OPTION in
            1)
                SELECTED_USER=$current_user
                log "info" "Using current user: $SELECTED_USER"
                break
                ;;
                
            2)
                show_header
                print_section_header "New User Creation"
                echo -e "${YELLOW}Creating a new dedicated user account for ETLegacy servers.${NC}\n"
                
                while true; do
                    log "prompt" "Username Requirements:"
                    log "info" "• Start with lowercase letter"
                    log "info" "• Use only lowercase letters, numbers, dash (-) or underscore (_)"
                    echo
                    
                    read -p "Enter username: [default: etlserver] " new_user
                    
                    # Use default if empty
                    new_user=${new_user:-$default_server_user}
                    
                    # Check if user already exists
                    if id "$new_user" >/dev/null 2>&1; then
                        log "warning" "User '$new_user' already exists. Please choose a different username."
                        continue
                    fi
                    
                    # Validate username format
                    if ! [[ $new_user =~ ^[a-z][a-z0-9_-]*$ ]]; then
                        log "warning" "Invalid username format. Username must:"
                        log "info" "• Start with a lowercase letter"
                        log "info" "• Contain only lowercase letters, numbers, dash (-) or underscore (_)"
                        log "info" "• Example valid usernames: etlserver, etl-server, etl_server1\n"
                        continue
                    fi
                    
                    echo -e "\n${YELLOW}Creating user account...${NC}"
                    if useradd -m -s /bin/bash "$new_user"; then
                        while true; do
                            echo
                            log "prompt" "Set password for $new_user"
                            log "info" "Minimum 8 characters required"
                            echo
                            read -s -p "Enter password: " password
                            echo
                            read -s -p "Confirm password: " password2
                            echo

                            if [ "$password" != "$password2" ]; then
                                log "error" "Passwords do not match. Please try again."
                                continue
                            fi
                            
                            if [ ${#password} -lt 8 ]; then
                                log "error" "Password must be at least 8 characters long."
                                continue
                            fi

                            # Use openssl to create password hash and set it directly
                            HASH=$(echo "$password" | openssl passwd -6 -stdin)
                            if echo "$new_user:$HASH" | chpasswd -e; then
                                SELECTED_USER=$new_user
                                log "success" "User setup complete: $SELECTED_USER"
                                export SELECTED_USER
                                return 0  # Return immediately after successful user creation
                            else
                                log "error" "Failed to set password. Removing user..."
                                userdel -r "$new_user" >/dev/null 2>&1
                                break  # Break inner loop on failure
                            fi
                        done
                    else
                        log "error" "Failed to create user '$new_user'. Please try again."
                    fi
                done
                ;;
                
            3)
                show_header
                print_section_header "Existing User Selection"
                log "prompt" "Available system users:"
                echo
                
                # Get and display list of regular users (UID >= 1000, excluding nobody)
                while IFS=: read -r username _ uid _; do
                    if [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ]; then
                        log "info" "• $username (UID: $uid)"
                    fi
                done < /etc/passwd
                echo

                while true; do
                    read -p "Enter username (or 'back' to return to main menu): " selected_user
                    
                    if [ "$selected_user" = "back" ]; then
                        echo
                        break
                    fi
                    
                    # Validate user exists and is a regular user
                    if id "$selected_user" >/dev/null 2>&1; then
                        local uid=$(id -u "$selected_user")
                        if [ $uid -ge 1000 ] && [ $uid != 65534 ]; then
                            SELECTED_USER=$selected_user
                            break 2
                        else
                            log "warning" "Please select a regular user account (UID >= 1000)"
                        fi
                    else
                        log "warning" "User '$selected_user' does not exist. Please try again."
                    fi
                done
                ;;
                
            *)
                log "warning" "Invalid option. Please select 1, 2, or 3."
                ;;
        esac
    done
    
    if [ -z "$SELECTED_USER" ]; then
        log "error" "No user was selected"
        return 1
    fi
    
    log "success" "User setup complete: $SELECTED_USER"
    export SELECTED_USER
    sleep 2
    return 0
}

install_docker() {
    show_header
    print_section_header "Docker Installation"
    
    # Version requirements
    local min_docker_version="20.10.0"
    local min_compose_version="2.0.0"
    
    # Check if Docker is already installed
    if command -v docker >/dev/null 2>&1; then
        local current_docker_version=$(docker --version | cut -d" " -f3 | tr -d ",v")
        log "info" "Docker ${current_docker_version} is installed"
        
        version_compare() {
            local v1="$1"
            local v2="$2"
            
            # Normalize versions by padding with zeros
            local ver1=(${v1//./ })
            local ver2=(${v2//./ })
            
            # Fill arrays with zeros if needed
            while [ ${#ver1[@]} -lt 3 ]; do ver1+=("0"); done
            while [ ${#ver2[@]} -lt 3 ]; do ver2+=("0"); done
            
            for i in {0..2}; do
                if [ "${ver1[$i]}" -gt "${ver2[$i]}" ]; then
                    return 0
                elif [ "${ver1[$i]}" -lt "${ver2[$i]}" ]; then
                    return 1
                fi
            done
            return 0  # Versions are equal
        }
        
        if ! version_compare "$current_docker_version" "$min_docker_version"; then
            log "warning" "Docker version ${current_docker_version} is older than minimum required version ${min_docker_version}"
            log "info" "Recommended to update Docker"
            read -p "Would you like to reinstall Docker? (y/N): " REINSTALL
            if [[ ! $REINSTALL =~ ^[Yy]$ ]]; then
                return 0
            fi
        else
            log "success" "Docker version is compatible"
            read -p "Would you like to reinstall Docker anyway? (y/N): " REINSTALL
            if [[ ! $REINSTALL =~ ^[Yy]$ ]]; then
                return 0
            fi
        fi
    fi
    
    log "info" "Installing Docker using official installation script..."
    
    # Create temporary directory
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"
    
    # Download and verify the installation script
    echo -n "Downloading Docker installation script... "
    if curl -fsSL https://get.docker.com -o get-docker.sh; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        cd - >/dev/null
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Run the installation script
    echo -n "Installing Docker... "
    if sh ./get-docker.sh &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        cd - >/dev/null
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Clean up
    cd - >/dev/null
    rm -rf "$tmp_dir"
    
    # Start and enable Docker service
    echo -n "Starting Docker service... "
    if systemctl start docker &>/dev/null && systemctl enable docker &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        log "error" "Docker service failed to start. Check logs with: journalctl -xeu docker"
        return 1
    fi

    # Verify Docker Compose
    echo -n "Checking Docker Compose... "
    if docker compose version &>/dev/null; then
        local compose_version=$(docker compose version --short)
        if version_compare "$compose_version" "$min_compose_version"; then
            echo -e "${GREEN}OK${NC}"
            log "info" "Docker Compose ${compose_version} detected"
        else
            echo -e "${YELLOW}UPDATE RECOMMENDED${NC}"
            log "warning" "Docker Compose ${compose_version} is older than recommended version ${min_compose_version}"
        fi
    else
        echo -e "${RED}NOT FOUND${NC}"
        log "error" "Docker Compose not available. Please install Docker Compose separately."
        return 1
    fi
    
    # Add user to docker group
    if [ -n "$SELECTED_USER" ]; then
        echo -n "Adding $SELECTED_USER to docker group... "
        if usermod -aG docker "$SELECTED_USER"; then
            echo -e "${GREEN}OK${NC}"
            log "info" "User $SELECTED_USER added to docker group"
        else
            echo -e "${RED}FAILED${NC}"
            log "error" "Failed to add user to docker group"
            return 1
        fi
    fi

    # Print versions
    docker_version=$(docker --version)
    compose_version=$(docker compose version)
    log "success" "Docker installation completed successfully!"
    log "info" "$docker_version"
    log "info" "$compose_version"

    # Reminder about group membership
    if [ -n "$SELECTED_USER" ]; then
        log "info" "Note: You'll need to log out and back in for docker group membership to take effect."
    fi

    sleep 2
    return 0
}

detect_docker_compose_command() {
    # Try docker compose first (newer method)
    if docker compose version &>/dev/null; then
        echo "docker compose"
        return 0
    # Then try docker-compose (legacy method)
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
        return 0
    else
        return 1
    fi
}

configure_server_instances() {
    show_header
    print_section_header "Server Instance Configuration"
    
    log "prompt" "ETLegacy Server Instances Setup"
    log "" "Each instance represents a separate game server that can run independently."
    log "" "Each server instance:"
    log ""  "  • Uses a unique UDP port (starting from 27960)"
    log ""  "  • Has its own configuration and settings"
    log ""  "  • Requires additional system resources\n"
    echo 
    echo
    log "prompt" "Recommended settings:"
    log "" "• 1-3 instances for basic setup"
    log "" "• Ensure you have enough system resources for each instance"
    log "" "  - ~ 256MB RAM per instance, 512MB better"
    log "" "  - ~ 1 CPU core per instance\n"
    echo
    echo

    while true; do
        read -p "How many server instances? [default: 1]: " INSTANCES
        INSTANCES=${INSTANCES:-1}
        
        if [[ "$INSTANCES" =~ ^[0-9]+$ ]] && [ "$INSTANCES" -gt 0 ] && [ "$INSTANCES" -le 10 ]; then
            break
        fi
        log "error" "Please enter a valid number between 1 and 10"
    done

    log "success" "Configuring $INSTANCES server instance(s)"
    sleep 1
    show_header
    
    export INSTANCES
}
setup_maps() {
    local install_dir="$1"
    local maps_txt="$install_dir/maps.txt"
    local failed_maps="$install_dir/failed_maps.txt"
    local repo_url=""
    
    show_header
    print_section_header "Map Configuration"
    
    log "prompt" "Map Download Configuration for ET:Legacy Docker:"
    log "info" "Option 1: Persistent Volume (Recommended)"
    log "" "  • Maps are downloaded once and shared across all server instances"
    log "" "  • Faster server startup times"
    log "" "  • Reduced bandwidth usage"
    log "" "  • Ideal for multiple server instances"
    log "" "  • Allows us to setup a webserver for wwwDownloads"
    echo
    echo
    log "info" "Option 2: Container Downloads"
    log "" "  • Each container downloads maps on startup"
    log "" "  • Increased startup time"
    log "" "  • Higher bandwidth usage"
    log "" "  • Not recommended for multiple instances"
    echo
    echo
    
    read -p "Use persistent volume for maps? [default: 1] (Y/n): " PREDOWNLOAD
    export PREDOWNLOAD
    
    if [[ $PREDOWNLOAD =~ ^[Nn]$ ]]; then
        log "warning" "Note: Each container will need to download maps on every restart."
        log "info" "Configuring container map downloads..."
        return 0
    fi
    
    setup_directory "$install_dir/maps/etmain" "$SELECTED_USER" || return 1
    
    show_header
    print_section_header "Map Repository Selection" "(These settings can be changed later)"
    log "prompt" "Select a server to download from"
    log "" "  1. dl.etl.lol (comp maps only)"
    log "" "  2. download.hirntot.org (huge variety)"
    log "" "  3. moestavern.site.nfoservers.com/downloads/et (moe)"
    log "" "  4. Custom repository URL"
    echo
    echo
    read -p "Select repository [default: 1] (1-4): " REPO_CHOICE
    
    case $REPO_CHOICE in
        1) repo_url="https://dl.etl.lol/maps/et" ;;
        2) repo_url="https://download.hirntot.org" ;;
        3) repo_url="http://moestavern.site.nfoservers.com/downloads/et" ;;
        4) 
            echo -e "\n${YELLOW}Enter custom repository URL:${NC}"
            read -p "> " repo_url
            # Remove trailing /etmain if present
            repo_url="${repo_url%/etmain}"
            ;;
        *) 
            log "warning" "Invalid choice. Using default repository."
            repo_url="https://dl.etl.lol/maps/et"
            ;;
    esac
    
    # Store the repository URL in settings
    store_setting "Additional Settings" "REDIRECTURL" "${repo_url}"
    
    show_header
    print_section_header "Map Selection" "(These settings can be changed later)"
    log "prompt" "Default competitive map list:"
    echo -e "$DEFAULT_MAPS" | fold -s -w 80
    echo
    echo

    local maplist="$DEFAULT_MAPS"
    
    # Ask for additional maps
    log "prompt" "Would you like to add more maps to the default list?"
    log "info" "  • The full mapname is required."
    log "info" "  • Maps may not be available, depending on repository used." 
    log "info" "  • You can add them to maps/ folder manually later."
    echo
    log "prompt" "Examples of additional maps:"
    log "" "  • etl_base_v3 mp_sillyctf"
    log "" "  • goldendunk_a2 te_rifletennis ctf_well"
    log "" "  • ctf_multi"
    echo 
    echo 
    
    read -p "Add additional maps? (y/N): " ADD_MAPS
    if [[ $ADD_MAPS =~ ^[Yy]$ ]]; then
        read -p "Enter additional maps (space-separated): " ADDITIONAL_MAPS
        if [ ! -z "$ADDITIONAL_MAPS" ]; then
            maplist="$maplist $ADDITIONAL_MAPS"
            echo
            log "info" "Final map list:"
            echo "$maplist" | fold -s -w 80
            echo
            sleep 3
        fi
    fi
    
    # Create temporary files for map processing
    > "$maps_txt"
    > "$failed_maps"

    # Process maps and store in settings
    local maps_env=""
    for map in $maplist; do
        map=$(check_pk3 "$map")
        echo "$map" >> "$maps_txt"
        map_name=$(basename "$map" ".pk3")
        maps_env="${maps_env}${map_name}:"
    done

    store_setting "Map Settings" "MAPS" "${maps_env%:}"

    # Download maps
    echo
    log "info" "Starting map downloads from $repo_url..."
    log "warning" "This may take a while..."

    # Use a temporary file for download progress
    local progress_file=$(mktemp)

    # First attempt - try with /etmain path
    parallel --eta --jobs 30 --progress \
        "wget -q -P \"$install_dir/maps/etmain\" \"$repo_url/etmain/{}\" 2>/dev/null || 
        echo {} >> \"$failed_maps\"; 
        echo \"Downloaded: {}\" >> \"$progress_file\"" \
        :::: "$maps_txt"

    # Second attempt for failed downloads - try without /etmain path
    if [ -s "$failed_maps" ]; then
        log "info" "Retrying failed downloads without /etmain path..."
        local retry_maps=$(mktemp)
        cp "$failed_maps" "$retry_maps"
        > "$failed_maps"  # Clear failed_maps for second attempt

        parallel --eta --jobs 30 --progress \
            "wget -q -P \"$install_dir/maps/etmain\" \"$repo_url/{}\" 2>/dev/null || 
            echo {} >> \"$failed_maps\"; 
            echo \"Downloaded: {}\" >> \"$progress_file\"" \
            :::: "$retry_maps"
            
        rm -f "$retry_maps"
    fi

    # Display download results
    if [ -f "$progress_file" ]; then
        while IFS= read -r line; do
            if [[ $line == Downloaded:* ]]; then
                echo -e "${GREEN}✓${NC} ${line#Downloaded: }"
            fi
        done < "$progress_file"
        rm -f "$progress_file"
    fi
    
    # Check for failed downloads
    if [ -s "$failed_maps" ]; then
        log "warning" "The following maps failed to download:"
        cat "$failed_maps" | while read map; do
            echo -e "${YELLOW}• $map${NC}"
        done
        log "info" "You may need to download these maps manually or try a different repository"
    else
        log "success" "All maps downloaded successfully!"
    fi

    # Cleanup
    rm -f "$maps_txt" "$failed_maps"
    sleep 3
    
    show_header
}

setup_map_environment() {
    if [[ ! $PREDOWNLOAD =~ ^[Nn]$ ]]; then
        return 0
    fi
    
    show_header
    print_section_header "Container Map Download Configuration"
    
    log "prompt" "Container Map Download Setup:"
    log "" "  • Each container will download maps on startup"
    log "" "  • This may increase server startup time"
    log "" "  • Higher bandwidth usage with multiple instances"
    log "" "  • Maps will be downloaded from: download.hirntot.org\n"
    
    log "warning" "Since you chose not to pre-download maps, containers will download them as needed."
    
    # Convert default maps to colon-separated list
    local maps_env=""
    for map in $DEFAULT_MAPS; do
        map=$(echo "$map" | sed 's/\.pk3$//')
        maps_env="${maps_env}${maps_env:+:}${map}"
    done
    
    read -p "Would you like to add additional maps? (y/N): " ADD_MAPS
    if [[ $ADD_MAPS =~ ^[Yy]$ ]]; then
        log "prompt" "Enter additional maps (space-separated):"
        read -p "> " ADDITIONAL_MAPS
        for map in $ADDITIONAL_MAPS; do
            map=$(echo "$map" | sed 's/\.pk3$//')
            maps_env="${maps_env}:${map}"
        done
    fi
    
    # Store settings
    store_setting "Map Settings" "MAPS" "$maps_env"
    store_setting "Additional Settings" "REDIRECTURL" "https://download.hirntot.org"
    
    log "success" "Map download configuration completed!"
    sleep 2
}

configure_setting() {
    local setting="$1"
    local default="$2"
    local description="$3"
    local category="$4"
    local is_global="${5:-false}"
    
    show_header
    print_section_header "$setting Configuration"
    echo -e "${YELLOW}$description${NC}\n"
    
    read -p "Enter value for $setting [default: $default]: " value
    value=${value:-$default}
    
    # If multiple instances are configured, handle per-server settings
    if [ "$INSTANCES" -gt 1 ] && [ "$is_global" != "true" ]; then
        log "info" "Apply this setting:"
        log "prompt" "1. Globally (all instances)"
        log "prompt" "2. Per-server (specific instances)"
        
        read -p "Choose option (1/2) [default: 1]: " scope
        scope=${scope:-1}
        
        if [ "$scope" = "2" ]; then
            for i in $(seq 1 $INSTANCES); do
                log "prompt" "Apply to Server $i? (Y/n)"
                read -p "> " apply
                if [[ ! $apply =~ ^[Nn]$ ]]; then
                    store_server_setting "$i" "$setting" "$value"
                fi
            done
        else
            store_setting "$category" "$setting" "$value" "true"
        fi
    else
        store_setting "$category" "$setting" "$value" "$is_global"
    fi
}

# Configure server settings
configure_server_settings() {
    while true; do
        show_header
        print_section_header "Server Configuration Settings." "(These settings can be changed later)"
        log "prompt" "Configure server settings. Default values will be used if skipped. (Recommended in most cases)"
        log "prompt" "Most of these can be left alone. You can always change them later."
        log "prompt" "See https://github.com/Oksii/etlegacy"
        echo
        echo
        
        log "prompt" "Basic Settings:"
        echo -e "${BLUE}     1. STARTMAP               ${NC}- Starting map (default: radar)"
        echo -e "${BLUE}     2. MAXCLIENTS             ${NC}- Maximum players (default: 32)"
        echo -e "${BLUE}     3. AUTO_UPDATE            ${NC}- Auto-update configs (default: true)"
        echo -e "${BLUE}     4. CONF_MOTD$             ${NC}- Message of the day (default: none)"
        echo -e "${BLUE}     5. SERVERCONF             ${NC}- Config to load (default: legacy6)"
        echo -e "${BLUE}     6. TIMEOUTLIMIT           ${NC}- Max pauses per side (default: 1)"
        echo -e "${BLUE}     7. ETLTV Settings         ${NC}- Configure ETLTV options"
        echo -e "${BLUE}     8. Advanced Settings      ${NC}- Configure advanced options"
        log "success" "  9. Done"
        echo
        echo

        read -p "Select option (1-9) [default: 9]: " option
        option=${option:-9}

        case $option in
            1) configure_setting "STARTMAP" "radar" "Map server starts on" "Server Settings" ;;
            2) configure_setting "MAXCLIENTS" "32" "Maximum number of players" "Server Settings" ;;
            3) configure_setting "AUTO_UPDATE" "true" "Update configurations on restart" "Server Settings" "true" ;;
            4) configure_motd ;;
            5) configure_setting "SERVERCONF" "legacy6" "Configuration to load on startup" "Server Settings" ;;
            6) configure_setting "TIMEOUTLIMIT" "1" "Maximum number of pauses per map side" "Server Settings" ;;
            7) configure_etltv_menu ;;
            8) configure_advanced_settings ;;
            9) break ;;
            *) log "warning" "Invalid option" ; sleep 1 ;;
        esac
    done
}


# Configure advanced settings
configure_advanced_settings() {
    while true; do
        show_header
        print_section_header "prompt" "Advanced Configuration Settings" "(These settings can be changed later)"
        log "warning" "Warning: These settings are for advanced users. Use default values if unsure."

        echo -e "${BLUE}     1. Download Settings      ${NC}- Configure REDIRECTURL"
        echo -e "${BLUE}     2. Tracker Settings       ${NC}- Configure SVTRACKER"
        echo -e "${BLUE}     3. XMAS Settings          ${NC}- Configure XMAS options"
        echo -e "${BLUE}     4. Repository Settings    ${NC}- Configure git settings"
        echo -e "${BLUE}     5. Demo Settings          ${NC}- Configure SVAUTODEMO"
        echo -e "${BLUE}     6. CLI Settings           ${NC}- Configure additional arguments"
        log "success" "  7. Back"
        echo
        echo
        
        read -p "Select option (1-7) [default: 7]: " option
        option=${option:-7}
        
        case $option in
            1) configure_setting "REDIRECTURL" "" "URL for HTTP downloads" "Download Settings" "true" ;;
            2) configure_setting "SVTRACKER" "" "Server tracker endpoint" "Tracker Settings" "true" ;;
            3) configure_xmas_menu ;;
            4) configure_repo_menu ;;
            5) configure_setting "SVAUTODEMO" "0" "Auto demo recording (0=off, 1=always, 2=if players connected)" "Demo Settings" "true" ;;
            6) configure_setting "ADDITIONAL_CLI_ARGS" "" "Additional command line arguments" "CLI Settings" "true" ;;
            7) return 0 ;;
            *) log "warning" "Invalid option" ; sleep 1 ;;
        esac
    done
}

# Function to convert Q3 color codes to ANSI escape sequences
q3_to_ansi() {
    local text="$1"
    local colored_text="$text"
    
    # Complete color mappings with all variants
    declare -A color_map=(
        ['^0']=$'\e[30m' ['^P']=$'\e[30m' ['^p']=$'\e[30m'                   # Black (#000000)
        ['^1']=$'\e[31m' ['^Q']=$'\e[31m' ['^q']=$'\e[31m'                   # Red (#ff0000)
        ['^2']=$'\e[32m' ['^R']=$'\e[32m' ['^r']=$'\e[32m'                   # Green (#00ff00)
        ['^3']=$'\e[33m' ['^S']=$'\e[33m' ['^s']=$'\e[33m'                   # Yellow (#ffff00)
        ['^4']=$'\e[34m' ['^T']=$'\e[34m' ['^t']=$'\e[34m'                   # Blue (#0000ff)
        ['^5']=$'\e[36m' ['^U']=$'\e[36m' ['^u']=$'\e[36m'                   # Cyan (#00ffff)
        ['^6']=$'\e[35m' ['^V']=$'\e[35m' ['^v']=$'\e[35m'                   # Magenta (#ff00ff)
        ['^7']=$'\e[37m' ['^W']=$'\e[37m' ['^w']=$'\e[37m'                   # White (#ffffff)
        ['^8']=$'\e[38;5;214m' ['^X']=$'\e[38;5;214m' ['^x']=$'\e[38;5;214m' # Orange (#ff7f00)
        ['^9']=$'\e[90m' ['^Y']=$'\e[90m' ['^y']=$'\e[90m'                   # Grey (#7f7f7f)
        ['^:']=$'\e[37;1m' ['^Z']=$'\e[37;1m' ['^z']=$'\e[37;1m'             # Bright Grey (#bfbfbf)
        ['^;']=$'\e[37;1m' ['^[']=$'\e[37;1m' ['^{']=$'\e[37;1m'             # Bright Grey (#bfbfbf)
        ['^<']=$'\e[38;5;22m' ['^\\']=$'\e[38;5;22m' ['^|']=$'\e[38;5;22m'   # Dark Green (#007f00)
        ['^=']=$'\e[38;5;142m' ['^]']=$'\e[38;5;142m' ['^}']=$'\e[38;5;142m' # Olive (#7f7f00)
        ['^>']=$'\e[38;5;18m' ['^^']=$'\e[38;5;18m' ['^~']=$'\e[38;5;18m'    # Dark Blue (#00007f)
        ['^?']=$'\e[38;5;52m' ['^_']=$'\e[38;5;52m'                          # Dark Red (#7f0000)
        ['^@']=$'\e[38;5;94m' ['^`']=$'\e[38;5;94m'                          # Brown (#7f3f00)
        ['^!']=$'\e[38;5;214m' ['^A']=$'\e[38;5;214m' ['^a']=$'\e[38;5;214m' # Gold (#ff9919)
        ['^"']=$'\e[38;5;30m' ['^B']=$'\e[38;5;30m' ['^b']=$'\e[38;5;30m'    # Teal (#007f7f)
        ['^#']=$'\e[38;5;90m' ['^C']=$'\e[38;5;90m' ['^c']=$'\e[38;5;90m'    # Purple (#7f007f)
        ['^$']=$'\e[38;5;33m' ['^D']=$'\e[38;5;33m' ['^d']=$'\e[38;5;33m'    # Light Blue (#007fff)
        ['^%']=$'\e[38;5;93m' ['^E']=$'\e[38;5;93m' ['^e']=$'\e[38;5;93m'    # Violet (#7f00ff)
        ['^&']=$'\e[38;5;74m' ['^F']=$'\e[38;5;74m' ['^f']=$'\e[38;5;74m'    # Steel Blue (#3399cc)
        ["^'"]=$'\e[38;5;157m' ['^G']=$'\e[38;5;157m' ['^g']=$'\e[38;5;157m' # Light Green (#ccffcc)
        ['^(']=$'\e[38;5;22m' ['^H']=$'\e[38;5;22m' ['^h']=$'\e[38;5;22m'    # Dark Green (#006633)
        ['^)']=$'\e[38;5;196m' ['^I']=$'\e[38;5;196m' ['^i']=$'\e[38;5;196m' # Bright Red (#ff0033)
        ['^*']=$'\e[38;5;124m' ['^J']=$'\e[38;5;124m' ['^j']=$'\e[38;5;124m' # Dark Red (#b21919)
        ['^+']=$'\e[38;5;130m' ['^K']=$'\e[38;5;130m' ['^k']=$'\e[38;5;130m' # Brown (#993300)
        ['^,']=$'\e[38;5;172m' ['^L']=$'\e[38;5;172m' ['^l']=$'\e[38;5;172m' # Gold Brown (#cc9933)
        ['^-']=$'\e[38;5;143m' ['^M']=$'\e[38;5;143m' ['^m']=$'\e[38;5;143m' # Olive (#999933)
        ['^.']=$'\e[38;5;229m' ['^N']=$'\e[38;5;229m' ['^n']=$'\e[38;5;229m' # Light Yellow (#ffffbf)
        ['^/']=$'\e[38;5;227m' ['^O']=$'\e[38;5;227m' ['^o']=$'\e[38;5;227m' # Pale Yellow (#ffff7f)
    )
    
    # Replace each color code with its ANSI equivalent
    for code in "${!color_map[@]}"; do
        colored_text="${colored_text//$code/${color_map[$code]}}"
    done
    
    # Add reset code at the end
    colored_text="${colored_text}$'\e[0m'"
    
    echo -e "$colored_text"
}

# Function to preview MOTD lines
preview_motd() {
    local motd="$1"
    
    echo -e "\n${CYAN}Preview of current MOTD:${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    # Replace \n with actual newlines and convert color codes
    echo -e "$motd" | sed 's/\\n/\n/g' | while IFS= read -r line; do
        q3_to_ansi "$line"
    done
    echo -e "${YELLOW}----------------------------------------${NC}\n"
}

# Function to handle MOTD configuration
configure_motd() {
    local current_motd=""
    local motd_lines=()
    
    # Get current MOTD from settings if it exists
    current_motd=$(get_setting "Server Settings" "CONF_MOTD") || current_motd=""
    
    # If we have an existing MOTD, split it into lines
    if [[ -n "$current_motd" ]]; then
        IFS=$'\n' read -d '' -r -a motd_lines <<< "$(echo -e "${current_motd//\\n/$'\n'}")"
    else
        # Default MOTD lines
        motd_lines=(
            "^7**************************"
            "^7* ^3Welcome to ^2ET^5Legacy ^7*"
            "^7* ^6Server running on    ^7*"
            "^7* ^4ETLegacy ^1Docker    ^7*"
            "^7* ^2Enjoy your stay^7!    ^7*"
            "^7**************************"
        )
        current_motd=$(printf "%s\\n" "${motd_lines[@]}")
        current_motd=${current_motd%$'\n'} # Remove trailing newline
    fi

    while true; do
        show_header
        print_section_header "Message of the Day Configuration"
        preview_motd "$current_motd"
        
        echo -e "${BLUE}     1. server_motd0            ${NC}- First line"
        echo -e "${BLUE}     2. server_motd1            ${NC}- Second line"
        echo -e "${BLUE}     3. server_motd2            ${NC}- Third line"
        echo -e "${BLUE}     4. server_motd3            ${NC}- Fourth line"
        echo -e "${BLUE}     5. server_motd4            ${NC}- Fifth line"
        echo -e "${BLUE}     6. server_motd5            ${NC}- Sixth line"
        echo -e "${BLUE}     7. Enter full string       ${NC}- Set entire MOTD at once"
        log "success" "  8. Save and Exit"
        echo
        
        read -p "Select option (1-8) [default: 8]: " option
        option=${option:-8}

        case $option in
            [1-6])
                local line_index=$((option - 1))
                echo
                log "prompt" "Enter text for line $option (current: ${motd_lines[$line_index]:-empty})"
                read -p "> " new_line
                if [[ -n "$new_line" ]]; then
                    motd_lines[$line_index]="$new_line"
                    current_motd=$(printf "%s\\n" "${motd_lines[@]}")
                    current_motd=${current_motd%$'\n'} # Remove trailing newline
                fi
                ;;
            7)
                echo
                log "prompt" "Enter complete MOTD string (use \\n for line breaks):"
                log "info" "Example: ^7Line1\\n^7Line2\\n^7Line3"
                echo
                read -r full_motd
                if [[ -n "$full_motd" ]]; then
                    current_motd="$full_motd"
                    # Use printf to properly handle the newlines
                    mapfile -t motd_lines < <(printf '%s' "$full_motd" | sed 's/\\n/\n/g')
                fi
                ;;
            8)
                # If multiple instances are configured, handle per-server settings
                if [ "$INSTANCES" -gt 1 ]; then
                    log "info" "Apply this setting:"
                    log "prompt" "1. Globally (all instances)"
                    log "prompt" "2. Per-server (specific instances)"
                    
                    read -p "Choose option (1/2) [default: 1]: " scope
                    scope=${scope:-1}
                    
                    if [ "$scope" = "2" ]; then
                        for i in $(seq 1 $INSTANCES); do
                            log "prompt" "Apply to Server $i? (Y/n)"
                            read -p "> " apply
                            if [[ ! $apply =~ ^[Nn]$ ]]; then
                                store_server_setting "$i" "CONF_MOTD" "$current_motd"
                            fi
                        done
                    else
                        store_setting "Server Settings" "CONF_MOTD" "$current_motd" "true"
                    fi
                else
                    store_setting "Server Settings" "CONF_MOTD" "$current_motd" "false"
                fi
                return 0
                ;;
            *)
                log "warning" "Invalid option"
                sleep 1
                ;;
        esac
    done
}

configure_etltv_menu() {
    while true; do
        show_header
        print_section_header "ETLTV Settings" "(These settings can be changed later)"
        log "prompt" "Configure ETLTV settings for gamestv.org."
        echo -e "${BLUE}     1. SVETLTVMAXSLAVES       ${NC}- Max ETLTV slaves (default: 2)"
        echo -e "${BLUE}     2. SVETLTVPASSWORD        ${NC}- ETLTV password (default: 3tltv)"
        log "success" "  3. Back"
        echo
        echo
        
        read -p "Select option (1-3) [default: 3]: " option
        option=${option:-3}
        
        case $option in
            1)
                configure_setting "SVETLTVMAXSLAVES" "2" \
                    "Maximum amount of ETLTV slaves" \
                    "ETLTV" "true"
                ;;
            2)
                configure_setting "SVETLTVPASSWORD" "3tltv" \
                    "Password for ETLTV slaves" \
                    "ETLTV" "true"
                ;;
            3) return 0 ;;
            *) log "warning" "Invalid option" ; sleep 1 ;;
        esac
    done
}

configure_xmas_menu() {
    while true; do
        show_header
        print_section_header "XMAS Settings" "(These settings can be changed later)"
        log "warning" "Must provide valid direct URL to .pk3 file. This could be used to load any external .pk3"
        log "prompt" "Configure Christmas themed content settings."
        echo -e "${BLUE}     1. XMAS                   ${NC}- Enable XMAS content (default: false)"
        echo -e "${BLUE}     2. XMAS_URL               ${NC}- URL to download xmas.pk3"
        log "success" "  3. Back"
        echo
        echo 
        
        read -p "Select option (1-3) [default: 3]: " option
        option=${option:-3}
        
        case $option in
            1)
                configure_setting "XMAS" "false" \
                    "Enable XMAS content" \
                    "XMAS" "true"
                ;;
            2)
                configure_setting "XMAS_URL" "" \
                    "URL to download xmas.pk3" \
                    "XMAS" "true"
                ;;
            3) return 0 ;;
            *) log "warning" "Invalid option" ; sleep 1 ;;
        esac
    done
}

configure_repo_menu() {
    while true; do
        show_header
        print_section_header "Repository Settings" "(These settings can be changed later)"
        log "prompt" "Configure git repository settings."        
        echo -e "${BLUE}     1. SETTINGSURL            ${NC}- Github repository URL"
        echo -e "${BLUE}     2. SETTINGSPAT            ${NC}- Github PAT token"
        echo -e "${BLUE}     3. SETTINGSBRANCH         ${NC}- Github branch (default: main)"
        log "success" "  4. Back"
        echo
        echo
        
        read -p "Select option (1-4) [default: 4]: " option
        option=${option:-4}
        
        case $option in
            1)
                configure_setting "SETTINGSURL" \
                    "https://github.com/Oksii/legacy-configs.git" \
                    "Github repository URL" \
                    "Repository" "true"
                ;;
            2)
                configure_setting "SETTINGSPAT" "" \
                    "Github PAT token" \
                    "Repository" "true"
                ;;
            3)
                configure_setting "SETTINGSBRANCH" "main" \
                    "Github branch name" \
                    "Repository" "true"
                ;;
            4) return 0 ;;
            *) log "warning" "Invalid option" ; sleep 1 ;;
        esac
    done
}


setup_stats_variables() {
    show_header
    print_section_header "Stats Configuration" "(These settings can be changed later)"
    log "prompt" "Enable stats tracking to collect match data and player statistics."
    log "prompt" "Stats will automatically be submitted to https://stats.etl.lol"
    echo
    echo
    read -p "Would you like to enable stats submission? [default: yes] (Y/n): " ENABLE_STATS
    
    if [[ ! $ENABLE_STATS =~ ^[Nn]$ ]]; then
        store_setting "Stats Configuration" "STATS_SUBMIT" "true"
        store_setting "Stats Configuration" "STATS_API_TOKEN" "GameStatsWebLuaToken"
        store_setting "Stats Configuration" "STATS_API_URL_SUBMIT" "https://api.etl.lol/api/v2/stats/etl/matches/stats/submit"
        store_setting "Stats Configuration" "STATS_API_URL_MATCHID" "https://api.etl.lol/api/v2/stats/etl/match-manager"
        store_setting "Stats Configuration" "STATS_API_PATH" "/legacy/homepath/legacy/stats"
        store_setting "Stats Configuration" "STATS_API_LOG" "false"
        store_setting "Stats Configuration" "STATS_API_OBITUARIES" "false"
        store_setting "Stats Configuration" "STATS_API_DAMAGESTAT" "false"
        store_setting "Stats Configuration" "STATS_API_MESSAGELOG" "false"
        store_setting "Stats Configuration" "STATS_API_OBJSTATS" "true"
        store_setting "Stats Configuration" "STATS_API_SHOVESTATS" "true"
        store_setting "Stats Configuration" "STATS_API_DUMPJSON" "false"
    else
        store_setting "Stats Configuration" "STATS_SUBMIT" "false"
    fi

    log "success" "Stats collection enabled and configured!"
    sleep 2
}

configure_watchtower() {
    show_header
    print_section_header "Watchtower Configuration" "(Can be removed later)"
    log "info" "For more information see: https://containrrr.dev/watchtower/"
    echo
    log "prompt" "About Watchtower:"
    log "" "  • Automatically updates your ETLegacy and webserver Docker containers"
    log "" "  • Monitors for new versions of the server image"
    log "" "  • Performs graceful restarts when updates are available"
    log "" "  • Helps keep your servers up-to-date with latest features and fixes"
    echo
    log "prompt" "Benefits:"
    log "" "  • Automated maintenance"
    log "" "  • Always running latest version"
    log "" "  • Reduced downtime"
    log "" "  • Improved security"
    echo
    echo
    
    read -p "Would you like to enable Watchtower for automatic updates? (Y/n): " USE_WATCHTOWER
    if [[ ! $USE_WATCHTOWER =~ ^[Nn]$ ]]; then
        USE_WATCHTOWER="true"
        log "success" "Watchtower will be enabled"
    else
        USE_WATCHTOWER="false"
        log "info" "Watchtower will not be enabled"
    fi
    
    sleep 1
    return 0
}

# Add Watchtower service to docker-compose
add_watchtower_service() {
    cat >> docker-compose.yml << 'EOL'

  watchtower:
    container_name: watchtower
    image: containrrr/watchtower
    command: --enable-lifecycle-hooks
    networks:
      - etl
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.watchtower=watchtower"
    restart: unless-stopped
EOL
}

configure_auto_restart() {
    show_header
    print_section_header "Automatic Server Restart Configuration" "(Can be changed later)"
    log "info" "Adds a cron job to the $SELECTED_USER account. Scheduling can be changed manually from the default 2 hours"
    echo
    log "prompt" "About Automatic Restarts"
    log "" "  • Helps maintain server performance"
    log "" "  • Clears memory leaks"
    log "" "  • Ensures smooth operation"
    log "" "  • Only restarts when server is empty"
    echo
    echo
    
    read -p "Would you like to enable automatic server restarts every 2 hours? (Y/n): " ENABLE_RESTART
    if [[ ! $ENABLE_RESTART =~ ^[Nn]$ ]]; then
        for i in $(seq 1 $INSTANCES); do
            su - "$SELECTED_USER" -c "(crontab -l 2>/dev/null; echo \"0 */2 * * * docker exec etl-server$i ./autorestart\") | crontab -"
        done
        log "success" "Automatic restart cron jobs have been added for user $SELECTED_USER"
    else
        log "info" "Automatic restarts will not be enabled"
    fi
    
    sleep 2
    return 0
}

# Map all instance settings to docker-compose environment
map_instance_settings() {
    local instance=$1
    
    # Get all settings for this instance from settings.env
    grep "^SERVER${instance}_" "$SETTINGS_FILE" | while IFS='=' read -r key value; do
        # Extract the setting name without the SERVER{instance}_ prefix
        local setting=${key#SERVER${instance}_}
        
        # Add to environment section
        sed -i "/^  etl-server$instance:/,/^[^ ]/ {
            /environment:/a\      ${setting}: \${$key}
        }" docker-compose.yml
    done
}

generate_service() {
    local instance=$1
    local default_port=$((27960 + (instance - 1)))
    
    show_header
    print_section_header "Server $instance Configuration"
    log "prompt" "Required:"
    # Get required settings from user
    local port
    while true; do
        read -p "Server Port           [default: $default_port]: " port
        port=${port:-$default_port}
        
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
            log "error" "Invalid port number. Must be between 1024 and 65535"
            continue
        fi
        break
    done
    
    # Get hostname with default
    local default_hostname="ETL-Server $instance"
    read -p "Server Name           [default: $default_hostname]: " hostname
    hostname=${hostname:-"$default_hostname"}
    echo
    log "prompt" "Security Settings (Can be chaned later):"
    log "prompt" "Leaving these empty will disable them."
    read -p "Server Password       [default: empty]: " password
    read -p "RCON Password         [default: empty]: " rcon
    read -p "Referee Password      [default: empty]: " referee
    read -p "Shoutcaster Password  [default: empty]: " sc
    echo
    echo
    # Store all settings in settings.env
    store_server_setting "$instance" "MAP_PORT" "$port"
    store_server_setting "$instance" "HOSTNAME" "$hostname"
    
    # Store optional passwords only if they're not empreorganize_settings_filety
    [ -n "$password" ] && store_server_setting "$instance" "PASSWORD" "$password"
    [ -n "$rcon" ] && store_server_setting "$instance" "RCONPASSWORD" "$rcon"
    [ -n "$referee" ] && store_server_setting "$instance" "REFEREEPASSWORD" "$referee"
    [ -n "$sc" ] && store_server_setting "$instance" "SCPASSWORD" "$sc"

    # Generate only the basic service structure without environment variables
    cat >> docker-compose.yml << EOL

  etl-server$instance:
    <<: *common-core
    container_name: etl-server$instance
    environment:
    volumes:
      - "\${MAPSDIR}/etmain:/maps"
      - "\${LOGS}/etl-server$instance:/legacy/homepath/legacy/"
    ports:
      - '\${SERVER${instance}_MAP_PORT}:\${SERVER${instance}_MAP_PORT}/udp'
EOL
}

generate_docker_compose() {
    local install_dir=$1
    local instances=$2
    local use_watchtower=$3
    local use_webserver=$4

    show_header
    print_section_header "Generating Docker Compose Configuration"

    cat > docker-compose.yml << EOL
networks:
  etl:
    name: etl

x-common-core: &common-core
  image: oksii/etlegacy:\${VERSION}
  env_file: ${SETTINGS_FILE}
  networks:
    - etl
  stdin_open: true
  tty: true
  restart: unless-stopped
EOL

    if [[ $use_watchtower =~ ^[Yy]$ ]]; then
        cat >> docker-compose.yml << EOL
  labels:
    - "com.centurylinklabs.watchtower.enable=true"
    - "com.centurylinklabs.watchtower.lifecycle.pre-update=/legacy/server/autorestart"
EOL
    fi

    echo -e "\nservices:" >> docker-compose.yml

    # Generate individual services
    for ((i=1; i<=instances; i++)); do
        log "info" "Configuring server instance $i..."
        generate_service "$i" || {
            log "error" "Failed to configure server $i"
            exit 1
        }
        map_instance_settings "$i"
        
        log "success" "Server $i configuration complete!"
    done

    # Add Watchtower service if enabled
    if [[ $use_watchtower == "true" ]]; then
        log "info" "Adding Watchtower service..."
        add_watchtower_service
    fi

    # Add Webserver service if enabled
    if [[ $use_webserver == "true" ]]; then
        log "info" "Adding Webserver service..."
        add_webserver_service
    fi

    log "success" "Docker Compose configuration generated successfully!"
    sleep 2
}

setup_volume_paths() {
    local install_dir="$1"
    store_setting "Volumes" "MAPSDIR" "$install_dir/maps"
    store_setting "Volumes" "LOGS" "$install_dir/logs"
}

create_helper_script() {
    local install_dir="$1"
    local instances="$2"

    show_header
    print_section_header "Creating Server Management Script"

    # Detect which docker compose command to use
    local compose_cmd
    compose_cmd=$(detect_docker_compose_command) || {
        log "error" "No Docker Compose command found"
        return 1
    }
    log "info" "Using Docker Compose command: $compose_cmd"

    cat > "$install_dir/etl-server" << EOL
#!/bin/bash
INSTALL_DIR="${install_dir}"
SETTINGS_FILE="${install_dir}/settings.env"
COMPOSE_CMD="${compose_cmd}"
cd "$INSTALL_DIR" || exit 1
EOL
    cat >> "$install_dir/etl-server" << 'EOL'
usage() {
    echo "ETLegacy Server Management Script"
    echo "================================"
    echo "Usage: $0 [start|stop|restart|status|logs|rcon] [instance_number] [command]"
    echo
    echo "Commands:"
    echo "  start    Start servers"
    echo "  stop     Stop servers"
    echo "  restart  Restart servers"
    echo "  status   Show server status"
    echo "  logs     Show live logs for a server"
    echo "  rcon     Execute RCON command on a server"
    echo "  update   Updates and restarts the server with the latest available image"
    echo
    echo "Examples:"
    echo "Management Utilities" 
    echo "  etl-server start             # Starts all servers"
    echo "  etl-server stop 2            # Stops server instance 2"
    echo "  etl-server restart 1         # Restarts server instance 1"
    echo "  etl-server logs 1            # Shows live logs for server 1"
    echo "  etl-server rcon 2 map supply # Executes 'map supply' command on server 2"
    echo "Status - Retrieves server stats and players"
    echo "  etl-server status            # Shows status of all servers"
    echo "  etl-server status 2          # Shows status of server 2"
    echo "Update utility - Update Docker images and restart containers"
    echo "  etl-server update            # Updates all server images if servers are empty"
    echo "  etl-server update 2          # Updates server instance 2 if empty"
    echo "  etl-server update --force    # Updates all servers regardless of players"
    echo "  etl-server update 2 --force  # Updates server instance 2 regardless of players"
    exit 1
}

# Format duration from seconds to human readable
format_duration() {
    local seconds=$1
    local days=$((seconds/86400))
    local hours=$(((seconds%86400)/3600))
    local minutes=$(((seconds%3600)/60))

    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

update_servers() {
    local instance="$1"
    local force="$2"
    
    if [ -z "$instance" ]; then
        echo "Checking all servers for active players..."
        local has_players=0
        local player_info=""
        
        # Check each server for players using existing parse_quakestat function
        for container in $(docker ps -a --filter "name=etl-server" --format "{{.Names}}" | sort); do
            local port=$(docker inspect "$container" | grep -Po '"MAP_PORT=\K[^"]*')
            local server_info=$(parse_quakestat "$container" "$port")
            
            if [ $? -eq 0 ]; then
                local name map players
                IFS='|' read -r name map players <<< "$server_info"
                
                if [ "${players:-0}" -gt 0 ]; then
                    has_players=1
                    player_info="${player_info}${container} (${name}): ${players} players on ${map}\n"
                fi
            fi
        done
        
        if [ $has_players -eq 1 ] && [ "$force" != "--force" ]; then
            echo -e "Warning: The following servers have active players:\n${player_info}"
            echo "Use 'update --force' to update anyway, or wait until the servers are empty."
            echo "You can check server status using: $0 status"
            exit 1
        fi
        
        echo "Updating all server images..."
        $COMPOSE_CMD --env-file=$SETTINGS_FILE pull
        
        if [ $? -eq 0 ]; then
            echo "Successfully pulled new images. Restarting services..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE up -d
        else
            echo "Error pulling images. Please check your connection and try again."
            exit 1
        fi
    else
        local service_name="etl-server$instance"
        local port=$(docker inspect "$service_name" | grep -Po '"MAP_PORT=\K[^"]*')
        local server_info=$(parse_quakestat "$service_name" "$port")
        
        if [ $? -eq 0 ]; then
            local name map players
            IFS='|' read -r name map players <<< "$server_info"
            
            if [ "${players:-0}" -gt 0 ] && [ "$force" != "--force" ]; then
                echo "Warning: Server $service_name ($name) has $players active players on map $map!"
                echo "Use 'update $instance --force' to update anyway, or wait until the server is empty."
                echo "You can check server status using: $0 status $instance"
                exit 1
            fi
        fi
        
        echo "Updating server $instance..."
        local image=$(docker inspect "$service_name" --format='{{.Config.Image}}' 2>/dev/null)
        
        if [ -z "$image" ]; then
            echo "Error: Container $service_name not found"
            exit 1
        fi
        
        echo "Pulling new image for $service_name..."
        docker pull "$image"
        
        if [ $? -eq 0 ]; then
            echo "Successfully pulled new image. Restarting service..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE up -d "$service_name"
        else
            echo "Error pulling image. Please check your connection and try again."
            exit 1
        fi
    fi
}

parse_quakestat() {
    local container="$1"
    local port="$2"
    local xml_output

    xml_output=$(docker exec "$container" quakestat -xml -rws "localhost:$port" 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Parse XML using grep and sed
    local name map players
    name=$(echo "$xml_output" | grep -oP '<name>\K[^<]+')
    map=$(echo "$xml_output" | grep -oP '<map>\K[^<]+')
    players=$(echo "$xml_output" | grep -oP '<numplayers>\K[^<]+')

    echo "$name|$map|$players"
}

get_container_status() {
    local container="$1"
    local state running_for status

    # Get container state (running/stopped)
    state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
    if [ -z "$state" ]; then
        echo "Container not found"
        return 1
    fi

    # Get uptime if running
    if [ "$state" = "running" ]; then
        running_for=$(docker inspect --format='{{.State.StartedAt}}' "$container" | xargs -I{} date -d {} +%s)
        now=$(date +%s)
        uptime=$((now - running_for))
        status="$state (up $(format_duration $uptime))"
    else
        status="$state"
    fi

    # Get environment variables using grep
    local hostname port password rconpass refpass
    hostname=$(docker inspect "$container" | grep -Po '"HOSTNAME=\K[^"]*' || echo "-")
    port=$(docker inspect "$container" | grep -Po '"MAP_PORT=\K[^"]*' || echo "-")
    password=$(docker inspect "$container" | grep -Po '"PASSWORD=\K[^"]*' || echo "-")
    rconpass=$(docker inspect "$container" | grep -Po '"RCONPASSWORD=\K[^"]*' || echo "-")
    refpass=$(docker inspect "$container" | grep -Po '"REFEREEPASSWORD=\K[^"]*' || echo "-")

    # Get additional server info if container is running
    local server_info map players name
    if [ "$state" = "running" ]; then
        server_info=$(parse_quakestat "$container" "$port")
        if [ $? -eq 0 ]; then
            IFS='|' read -r name map players <<< "$server_info"
        else
            name="-" map="-" players="-"
        fi
    else
        name="-" map="-" players="-"
    fi

    # Print status with fixed width columns
    printf "%-12s %-18s %-25s %-8s %-8s %-8s %-10s %-12s %-12s\n" \
           "$container" \
           "$status" \
           "${name:--}" \
           "${map:--}" \
           "${players:-0}/32" \
           "$port" \
           "$password" \
           "$rconpass" \
           "$refpass"
}

# Show status of containers
show_status() {
    local instance="$1"

    echo "ETLegacy Server Status"
    echo "===================="
    printf "%-12s %-18s %-25s %-8s %-8s %-8s %-10s %-12s %-12s\n" \
           "CONTAINER" "STATUS" "NAME" "MAP" "PLAYERS" "PORT" "PASSWORD" "RCONPASS" "REFPASS"
    echo "------------------------------------------------------------------------------------------------"

    if [ -n "$instance" ]; then
        get_container_status "etl-server$instance"
    else
        for container in $(docker ps -a --filter "name=etl-server" --format "{{.Names}}" | sort); do
            get_container_status "$container"
        done
    fi
}

execute_rcon() {
    local instance="$1"
    local command="$2"
    local container="etl-server$instance"

    # Get port and rconpass from container
    local port rconpass
    port=$(docker inspect "$container" | grep -Po '"MAP_PORT=\K[^"]*')
    rconpass=$(docker inspect "$container" | grep -Po '"RCONPASSWORD=\K[^"]*')

    if [ -z "$port" ] || [ -z "$rconpass" ]; then
        echo "Error: Could not get port or RCON password for server $instance"
        return 1
    fi

    # Execute RCON command and filter out the header
    docker exec "$container" icecon "localhost:$port" "$rconpass" -c "$command" | \
        awk 'NR>3' # Skip the first 3 lines (header)
}

if [ $# -lt 1 ]; then
    usage
fi

ACTION=$1
INSTANCE=$2

case $ACTION in
    start)
        if [ -z "$INSTANCE" ]; then
            echo "Starting all servers..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE up -d
        else
            echo "Starting server $INSTANCE..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE up -d etl-server$INSTANCE
        fi
        ;;
    stop)
        if [ -z "$INSTANCE" ]; then
            echo "Stopping all servers..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE down
        else
            echo "Stopping server $INSTANCE..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE stop etl-server$INSTANCE
        fi
        ;;
    restart)
        if [ -z "$INSTANCE" ]; then
            echo "Restarting all servers..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE restart
        else
            echo "Restarting server $INSTANCE..."
            $COMPOSE_CMD --env-file=$SETTINGS_FILE restart etl-server$INSTANCE
        fi
        ;;
    status)
        show_status "$INSTANCE"
        ;;
	logs)
        if [ -z "$INSTANCE" ]; then
            echo "Error: Instance number is required for logs command"
            echo "Usage: etl-server logs INSTANCE_NUMBER"
            exit 1
        else
            echo "Showing logs for server $INSTANCE..."
            docker logs -f "etl-server$INSTANCE"
        fi
        ;;
    rcon)
        if [ -z "$INSTANCE" ] || [ -z "$3" ]; then
            echo "Error: Instance number and command are required for RCON"
            echo "Usage: etl-server rcon INSTANCE_NUMBER COMMAND"
            exit 1
        else
            shift 2
            execute_rcon "$INSTANCE" "$*"
        fi
        ;;
    update)
        update_servers "$INSTANCE"
        ;;
    *)
        usage
        ;;
esac
EOL

    chmod +x "$install_dir/etl-server"
    chown "$SELECTED_USER:$SELECTED_USER" "$install_dir/etl-server"
    ln -sf "$install_dir/etl-server" /usr/local/bin/etl-server
    
    log "success" "Server management script created!"
    sleep 2
}

configure_webserver() {
    show_header
    print_section_header "Webserver Configuration" "(Can easily be removed later)"
    log "info" "Uses a custom minimal webserver in a docker container, see https://github.com/Oksii/tinywebserver"
    echo
    log "prompt" "About Webserver:"
    log "" "  • Allows players to download missing maps via cl_wwwDownload"
    log "" "  • Minimal resource usage (lightweight HTTP server)"
    log "" "  • Faster downloads for custom maps and legacy updates"
    echo
    echo 
    
    read -p "Would you like to enable the webserver? (Y/n): " ENABLE_WEBSERVER
    if [[ ! $ENABLE_WEBSERVER =~ ^[Nn]$ ]]; then
        log "info" "Configuring webserver..."
        
        # Get public IP
        local public_ip
        public_ip=$(curl -s 'https://api.ipify.org?format=json' | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
        
        if [ -z "$public_ip" ]; then
            log "warning" "Could not determine public IP. Please enter it manually."
            read -p "Enter your server's public IP: " public_ip
        fi
        
        echo -e "\n${YELLOW}Your webserver will be available at:${NC} http://$public_ip"
        
        local redirect_url="http://$public_ip"
        store_setting "Additional Settings" "REDIRECTURL" "$redirect_url"
        
        # Create legacy folder for maps
        setup_directory "$INSTALL_DIR/maps/legacy" "$SELECTED_USER" || return 1
        
        log "success" "Webserver configuration complete!"
        export USE_WEBSERVER="true"
    else
        log "info" "Webserver will not be enabled"
        export USE_WEBSERVER="false"
    fi
    
    sleep 2
    return 0
}

add_webserver_service() {
    cat >> docker-compose.yml << EOL

  tinywebserver:
    container_name: tinywebserver
    image: ghcr.io/oksii/tinywebserver
    networks:
      - etl
    ports:
      - "80:8000"
    volumes:
      - "\${MAPSDIR}:/data"
    restart: unless-stopped
EOL
}

post_deployment_tasks() {
    local install_dir="$1"
    
    print_section_header "Performing post-deployment tasks..."
    
    # Create legacy directory if it doesn't exist
    setup_directory "$install_dir/maps/legacy" "$SELECTED_USER"
    
    # Wait for etl-server1 container to be ready
    log "info" "Waiting for server container to be ready..."
    while ! docker container inspect etl-server1 >/dev/null 2>&1 || \
          [ "$(docker container inspect -f '{{.State.Status}}' etl-server1)" != "running" ]; do
        log "info" "Waiting for etl-server1 container to be running..."
        sleep 5
    done
    
    # Copy only .pk3 files from the legacy directory
    log "info" "Copying legacy pk3 files from server..."
    
    # First check if there are any .pk3 files
    if docker exec etl-server1 bash -c "ls /legacy/server/legacy/*.pk3 2>/dev/null"; then
        docker exec etl-server1 bash -c "cd /legacy/server/legacy && ls *.pk3" | while read -r file; do
            log "info" "Copying $file..."
            docker cp "etl-server1:/legacy/server/legacy/$file" "$install_dir/maps/legacy/"
        done
        log "success" "Legacy pk3 files copied successfully"
    else
        log "warning" "No .pk3 files found in /legacy/server/legacy/"
    fi
    
    log "success" "Post-deployment tasks completed"
    sleep 2
}

main() {
    export INSTALL_DIR=""
    local INSTANCES=1
    local USE_WATCHTOWER=""
    local PREDOWNLOAD=""
    
    if [ "$DEBUG" = "1" ]; then
        log "info" "Debug mode enabled"
        set -x
    fi
    
    # Initial checks
    check_system || exit 1
    check_root || exit 1
    install_requirements || exit 1
    setup_user || exit 1
    setup_installation_directory "$SELECTED_USER" || exit 1

    # Set up settings file path
    export SETTINGS_FILE="$INSTALL_DIR/settings.env"
    init_settings_manager "$INSTALL_DIR" "$SELECTED_USER"

    install_docker || exit 1
    cd "$INSTALL_DIR" || exit 1

    # Detect docker compose command
    local compose_cmd
    compose_cmd=$(detect_docker_compose_command) || exit 1
    export DOCKER_COMPOSE_CMD="$compose_cmd"

    setup_volume_paths "$INSTALL_DIR"
    setup_maps "$INSTALL_DIR"
    setup_map_environment
    setup_stats_variables
    configure_server_instances
    configure_server_settings "$INSTANCES"
    configure_auto_restart || true 
    configure_watchtower
    configure_webserver

    generate_docker_compose "$INSTALL_DIR" "$INSTANCES" "$USE_WATCHTOWER" "$USE_WEBSERVER"

    reorganize_settings_file
    review_settings

    create_helper_script "$INSTALL_DIR" "$INSTANCES"

    setup_directory "$INSTALL_DIR/logs" "$SELECTED_USER" || exit 1
    for i in $(seq 1 $INSTANCES); do
        setup_directory "$INSTALL_DIR/logs/etl-server$i" "$SELECTED_USER" || exit 1
    done

    chmod -R 777 "$INSTALL_DIR/logs"
    chown -R "$SELECTED_USER:$SELECTED_USER" "$INSTALL_DIR"

    show_header
        print_section_header "Setup complete. Finalizing."
        log "success" "Starting ETL servers..."

        # Check if we're using a newly created user
        if [[ $USER_OPTION == "2" ]]; then
            # For new users, start with root first time
            log "info" "Starting servers with root permissions first time..."
            cd "$INSTALL_DIR" && ./etl-server start
        else
            # For existing users, start as the selected user
            su - "$SELECTED_USER" -c "cd $INSTALL_DIR && ./etl-server start"
        fi

    post_deployment_tasks "$INSTALL_DIR"

    show_header "Installation Complete!"
    log "success" "Setup complete! Your ETL servers are now running..."
    echo
    log "info" "Servers are running under user: $SELECTED_USER"
    echo

    if [[ $USER_OPTION == "2" ]]; then
        print_section_header "User Step Required"
        log "warning" "Important: For a new user, please:"
        log "" "  1. Log out of your current session"
        log "" "  2. Log in as $SELECTED_USER"
        log "" "  3. Run 'etl-server restart' to ensure proper permissions"
        echo
    fi

    print_section_header "Server Management"
    log "prompt" "Use 'etl-server start|stop|restart|logs|status|rcon [instance_number]' to manage your servers."
    log "prompt" "Simply type 'etl-server' to display a list of examples and help message."
    echo

    print_section_header "Configuration"
    log "prompt" "You can edit any previous selected setting at any time by editing your configuration file." 
    log "prompt" "Found at: $INSTALL_DIR/settings.env"
    echo
    log "prompt" "For a full list of available environments and their uses visit:"
    log "prompt" "https://github.com/Oksii/etlegacy"
    echo
    log "prompt" "Variables can be set globally, or on a per-server basis. See example section on github."
    log "warning" "Editing 'settings.env' or 'docker-compose.yml' requires servers to be restarted!"
    echo

    print_section_header "Optional Services"
    log "prompt" "If you chose to install the webserver or watchtower and wish to remove them:"
    log "" "  1. Stop the services via 'etl-server stop'"
    log "" "  2. Edit $INSTALL_DIR/docker-compose.yml"
    log "" "  3. Remove the services 'watchtower' and 'tinywebserver'"
    log "" "  4. Issue 'etl-server start'"
    echo

    print_section_header "Logging"
    log "prompt" "To view server logs see $INSTALL_DIR/logs"
    log "prompt" "Alternatively: follow docker's logs via 'etl-server logs [instance_number]'"
    echo

    print_section_header "Uninstall/Re-install" 
    log "prompt" "If you wish to re-install or uninstall you can follow the instructions below"
    log "warning" "This will erase all your configuration settings."
    log "" "  etl-server stop && rm rf $INSTALL_DIR"
    echo  

    print_section_header "Network Configuration"
    log "warning" "Firewall Configuration:"
    log "success" "✓ IPTables/nftables/ufw/firewalld is automatically configured by docker"
    log "success" "✓ Make sure to forward the necessary ports on your router/server provider's firewall"
    echo

    # Server Ports
    log "prompt" "ETL-Server ports (udp):"
    for i in $(seq 1 $INSTANCES); do
        port=$(grep "SERVER${i}_MAP_PORT=" "$SETTINGS_FILE" | cut -d'=' -f2)
        if [ ! -z "$port" ]; then
            printf "${CYAN}  └─ Port ${port}${NC}\n"
        fi
    done

    # Webserver URL if enabled
    if grep -q "^REDIRECTURL=" "$SETTINGS_FILE"; then
        echo
        redirect_url=$(grep "^REDIRECTURL=" "$SETTINGS_FILE" | cut -d'=' -f2)
        log "prompt" "Webserver URL (tcp port 80):"
        printf "${CYAN}  └─ ${redirect_url}${NC}\n"
    fi

    echo
    log "warning" "Setup Complete!"
    echo

}

main