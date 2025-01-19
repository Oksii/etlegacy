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

# Color definitions for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

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
DEFAULT_MAPS="adlernest braundorf_b4 bremen_b3 decay_sw erdenberg_t2 et_brewdog_b6 et_ice et_operation_b7 etl_adlernest_v4 etl_frostbite_v17 etl_ice_v12 etl_sp_delivery_v5 frostbite karsiah_te2 missile_b3 supply_sp sw_goldrush_te te_escape2_fixed3 te_valhalla"

DEBUG=${DEBUG:-0}

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    case $level in
        "info")    echo -e "${BLUE}[INFO]${NC} $message" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "warning") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "error")   echo -e "${RED}[ERROR]${NC} $message" ;;
        "prompt")  echo -e "\n${CYAN}${BOLD}$message${NC}" ;;
        *)         echo -e "$message" ;;
    esac
}

show_header() {
    clear
    echo -e "${PURPLE}================================================${NC}"
    echo -e "${PURPLE}          ETLegacy Server Setup Script${NC}"
    echo -e "${PURPLE}================================================${NC}\n"
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
    log "prompt" "Settings Review"
    
    echo -e "${YELLOW}Current Settings Configuration:${NC}\n"
    
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
    log "prompt" "Installation Directory Setup"
    
    echo -e "${YELLOW}Please specify where to install ETLegacy Server files.${NC}"
    echo -e "${YELLOW}This directory will contain:${NC}"
    echo -e "• Server configuration files"
    echo -e "• Map files"
    echo -e "• Log files"
    echo -e "• Docker compose configuration\n"

    echo -e "Current User's Login: $current_user"
    echo -e "User's Home Directory: $user_home\n"
    
    read -p "Install to default path: [$default_dir] (Y/n): " USE_DEFAULT
    
    if [[ ! $USE_DEFAULT =~ ^[Nn]$ ]]; then
        install_dir="$default_dir"
    else
        show_header
        log "prompt" "Custom Installation Path"
        echo -e "${YELLOW}Enter the full path where you want to install ETLegacy Server:${NC}\n"
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
    log "prompt" "Installing Required Packages..."
    
    local os_type=$(get_os_type)
    log "info" "Detected OS: $os_type"
    
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
    log "prompt" "User Account Setup"
    
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
    
    echo -e "${YELLOW}Choose a user account for running the ETLegacy servers:${NC}\n"
    echo -e "1. ${BLUE}Use current user${NC} ($current_user)"
    echo -e "2. ${BLUE}Create new dedicated server user${NC}"
    echo -e "3. ${BLUE}Use different existing system user${NC}"
    echo -e "\n${YELLOW}Suggestion: Option $suggested_option${NC}\n"
    
    while true; do
        read -p "Select option (1-3) [default=$suggested_option]: " USER_OPTION
        USER_OPTION=${USER_OPTION:-$suggested_option}
        
        case $USER_OPTION in
            1)
                SELECTED_USER=$current_user
                log "info" "Using current user: $SELECTED_USER"
                break
                ;;
                
            2)
                show_header
                log "prompt" "New User Creation"
                echo -e "${YELLOW}Creating a new dedicated user account for ETLegacy servers.${NC}\n"
                
                while true; do
                    echo -e "${YELLOW}Username Requirements:${NC}"
                    echo -e "• Start with lowercase letter"
                    echo -e "• Use only lowercase letters, numbers, dash (-) or underscore (_)\n"
                    
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
                        echo -e "• Start with a lowercase letter"
                        echo -e "• Contain only lowercase letters, numbers, dash (-) or underscore (_)"
                        echo -e "• Example valid usernames: etlserver, etl-server, etl_server1\n"
                        continue
                    fi
                    
                    echo -e "\n${YELLOW}Creating user account...${NC}"
                    if useradd -m -s /bin/bash "$new_user"; then
                        while true; do
                            echo -e "\n${YELLOW}Set password for $new_user${NC}"
                            echo -e "${BLUE}Minimum 8 characters required${NC}\n"
                            read -s -p "Enter password: " password
                            echo
                            read -s -p "Confirm password: " password2
                            echo

                            if [ "$password" != "$password2" ]; then
                                echo -e "\n${RED}Passwords do not match. Please try again.${NC}"
                                continue
                            fi
                            
                            if [ ${#password} -lt 8 ]; then
                                echo -e "\n${RED}Password must be at least 8 characters long.${NC}"
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
                log "prompt" "Existing User Selection"
                echo -e "${YELLOW}Available system users:${NC}\n"
                
                # Get and display list of regular users (UID >= 1000, excluding nobody)
                echo -e "${BLUE}"
                awk -F: '$3 >= 1000 && $3 != 65534 {printf "• %s (UID: %s)\n", $1, $3}' /etc/passwd
                echo -e "${NC}\n"
                
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
    log "prompt" "Docker Installation"
    
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
    log "prompt" "Server Instance Configuration"
    
    echo -e "${YELLOW}ETLegacy Server Instances Setup${NC}"
    echo -e "\nEach instance represents a separate game server that can run independently."
    echo -e "Each server instance:"
    echo -e "• Uses a unique UDP port (starting from 27960)"
    echo -e "• Has its own configuration and settings"
    echo -e "• Requires additional system resources\n"
    
    echo -e "${BLUE}Recommended settings:${NC}"
    echo -e "• 1-3 instances for basic setup"
    echo -e "• Ensure you have enough system resources for each instance"
    echo -e "  - ~256MB RAM per instance, 512MB better"
    echo -e "  - ~1 CPU core per instance\n"

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
    log "prompt" "Map Configuration"
    
    echo -e "${YELLOW}Map Download Configuration for ET:Legacy Docker:${NC}"
    echo -e "\n${BLUE}Option 1: Persistent Volume (Recommended)${NC}"
    echo -e "• Maps are downloaded once and shared across all server instances"
    echo -e "• Faster server startup times"
    echo -e "• Reduced bandwidth usage"
    echo -e "• Ideal for multiple server instances"
    echo -e "• Allows us to setup a webserver for wwwDownloads"
    
    echo -e "\n${BLUE}Option 2: Container Downloads${NC}"
    echo -e "• Each container downloads maps on startup"
    echo -e "• Increased startup time"
    echo -e "• Higher bandwidth usage"
    echo -e "• Not recommended for multiple instances\n"
    
    read -p "Use persistent volume for maps? (Y/n): " PREDOWNLOAD
    export PREDOWNLOAD
    
    if [[ $PREDOWNLOAD =~ ^[Nn]$ ]]; then
        log "warning" "Note: Each container will need to download maps on every restart."
        log "info" "Configuring container map downloads..."
        return 0
    fi
    
    setup_directory "$install_dir/maps/etmain" "$SELECTED_USER" || return 1
    
    show_header
    log "prompt" "Map Repository Selection"
    echo -e "1. ${BLUE}dl.etl.lol${NC} (comp maps only)"
    echo -e "2. ${BLUE}download.hirntot.org${NC} (Alternative)"
    echo -e "3. ${BLUE}Custom repository URL${NC}\n"
    
    read -p "Select repository (1-3): " REPO_CHOICE
    
    case $REPO_CHOICE in
        1) repo_url="https://dl.etl.lol/maps/et/etmain" ;;
        2) repo_url="https://download.hirntot.org/etmain" ;;
        3) 
            echo -e "\n${YELLOW}Enter custom repository URL:${NC}"
            read -p "> " repo_url
            ;;
        *) 
            log "warning" "Invalid choice. Using default repository."
            repo_url="https://dl.etl.lol/maps/et/etmain"
            ;;
    esac
    
    show_header
    log "prompt" "Map Selection"
    echo -e "${YELLOW}Default competitive map list:${NC}"
    echo -e "$DEFAULT_MAPS" | fold -s -w 80
    echo

    local maplist="$DEFAULT_MAPS"
    
    # Ask for additional maps
    echo -e "\n${YELLOW}Would you like to add more maps to the default list?${NC}"
    echo -e "${BLUE}The full mapname is required.${NC}"
    echo -e "${BLUE}Maps may not be available, you can add them to maps/ folder manually later.${NC}"
    echo -e "${BLUE}Examples of additional maps:${NC}"
    echo -e "• etl_base_v3, mp_sillyctf"
    echo -e "• goldendunk_a2, te_rifletennis"
    echo -e "• ctf_multi ctf_well${NC}\n"
    
    read -p "Add additional maps? (y/N): " ADD_MAPS
    if [[ $ADD_MAPS =~ ^[Yy]$ ]]; then
        read -p "Enter additional maps (space-separated): " ADDITIONAL_MAPS
        if [ ! -z "$ADDITIONAL_MAPS" ]; then
            maplist="$maplist $ADDITIONAL_MAPS"
            echo -e "\n${BLUE}Final map list:${NC}"
            echo -e "$maplist" | fold -s -w 80
            echo
            sleep 2
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
    log "info" "Starting map downloads from $repo_url..."
    echo "This may take a while. Maps will be downloaded in parallel."

    # Use a temporary file for download progress
    local progress_file=$(mktemp)

    parallel --eta --jobs 30 --progress \
        "wget -q -P \"$install_dir/maps/etmain\" \"$repo_url/{}\" 2>/dev/null || 
        echo {} >> \"$failed_maps\"; 
        echo \"Downloaded: {}\" >> \"$progress_file\"" \
        :::: "$maps_txt"

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
    log "prompt" "Container Map Download Configuration"
    
    echo -e "${YELLOW}Container Map Download Setup:${NC}"
    echo -e "• Each container will download maps on startup"
    echo -e "• This may increase server startup time"
    echo -e "• Higher bandwidth usage with multiple instances"
    echo -e "• Maps will be downloaded from: download.hirntot.org\n"
    
    echo -e "${YELLOW}Since you chose not to pre-download maps, containers will download them as needed.${NC}\n"
    
    # Convert default maps to colon-separated list
    local maps_env=""
    for map in $DEFAULT_MAPS; do
        map=$(echo "$map" | sed 's/\.pk3$//')
        maps_env="${maps_env}${maps_env:+:}${map}"
    done
    
    read -p "Would you like to add additional maps? (y/N): " ADD_MAPS
    if [[ $ADD_MAPS =~ ^[Yy]$ ]]; then
        echo -e "\n${YELLOW}Enter additional maps (space-separated):${NC}"
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
    log "prompt" "$setting Configuration"
    echo -e "${YELLOW}$description${NC}\n"
    
    read -p "Enter value for $setting [default: $default]: " value
    value=${value:-$default}
    
    # If multiple instances are configured, handle per-server settings
    if [ "$INSTANCES" -gt 1 ] && [ "$is_global" != "true" ]; then
        echo -e "\nApply this setting:"
        echo -e "1. ${BLUE}Globally${NC} (all instances)"
        echo -e "2. ${BLUE}Per-server${NC} (specific instances)\n"
        
        read -p "Choose option (1/2) [default: 1]: " scope
        scope=${scope:-1}
        
        if [ "$scope" = "2" ]; then
            for i in $(seq 1 $INSTANCES); do
                echo -e "\nApply to Server $i? (Y/n)"
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
        log "prompt" "Server Configuration Settings"
        echo -e "${YELLOW}Configure server settings. Default values will be used if skipped.${NC}\n"
        echo -e "${YELLOW}Most of these can be left alone. You can always change them later.${NC}\n"
        echo -e "${YELLOW}See https://github.com/Oksii/etlegacy${NC}\n\n"
        
        echo -e "Basic Settings:"
        echo -e "1. ${BLUE}STARTMAP${NC}          - Starting map (default: radar)"
        echo -e "2. ${BLUE}MAXCLIENTS${NC}        - Maximum players (default: 32)"
        echo -e "3. ${BLUE}AUTO_UPDATE${NC}       - Auto-update configs (default: true)"
        echo -e "4. ${BLUE}CONF_MOTD${NC}         - Message of the day"
        echo -e "5. ${BLUE}SERVERCONF${NC}        - Config to load (default: legacy6)"
        echo -e "6. ${BLUE}TIMEOUTLIMIT${NC}      - Max pauses per side (default: 1)"
        echo -e "7. ${BLUE}ETLTV Settings${NC}    - Configure ETLTV options"
        echo -e "8. ${BLUE}Advanced Settings${NC} - Configure advanced options"
        echo -e "9. ${GREEN}Done${NC}\n"
        
        read -p "Select option (1-9) [default: 9]: " option
        option=${option:-9}
        
        case $option in
            1) configure_setting "STARTMAP" "radar" "Map server starts on" "Server Settings" ;;
            2) configure_setting "MAXCLIENTS" "32" "Maximum number of players" "Server Settings" ;;
            3) configure_setting "AUTO_UPDATE" "true" "Update configurations on restart" "Server Settings" "true" ;;
            4) configure_setting "CONF_MOTD" "" "Message of the day shown on connect" "Server Settings" ;;
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
        log "prompt" "Advanced Configuration Settings"
        echo -e "${YELLOW}Warning: These settings are for advanced users. Use default values if unsure.${NC}\n"
        
        echo -e "1. ${BLUE}Download Settings${NC}   - Configure REDIRECTURL"
        echo -e "2. ${BLUE}Tracker Settings${NC}    - Configure SVTRACKER"
        echo -e "3. ${BLUE}XMAS Settings${NC}       - Configure XMAS options"
        echo -e "4. ${BLUE}Repository Settings${NC} - Configure git settings"
        echo -e "5. ${BLUE}Demo Settings${NC}       - Configure SVAUTODEMO"
        echo -e "6. ${BLUE}CLI Settings${NC}        - Configure additional arguments"
        echo -e "7. ${GREEN}Back${NC}\n"
        
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

configure_etltv_menu() {
    while true; do
        show_header
        log "prompt" "ETLTV Settings"
        echo -e "${YELLOW}Configure ETLTV settings for demo recording and streaming.${NC}\n"
        
        echo -e "1. ${BLUE}SVETLTVMAXSLAVES${NC} - Max ETLTV slaves (default: 2)"
        echo -e "2. ${BLUE}SVETLTVPASSWORD${NC}  - ETLTV password (default: 3tltv)"
        echo -e "3. ${GREEN}Back${NC}\n"
        
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
        log "prompt" "XMAS Settings"
        echo -e "${YELLOW}Configure Christmas themed content settings.${NC}\n"
        
        echo -e "1. ${BLUE}XMAS${NC}      - Enable XMAS content (default: false)"
        echo -e "2. ${BLUE}XMAS_URL${NC}  - URL to download xmas.pk3"
        echo -e "3. ${GREEN}Back${NC}\n"
        
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
        log "prompt" "Repository Settings"
        echo -e "${YELLOW}Configure git repository settings.${NC}\n"
        
        echo -e "1. ${BLUE}SETTINGSURL${NC}    - Github repository URL"
        echo -e "2. ${BLUE}SETTINGSPAT${NC}    - Github PAT token"
        echo -e "3. ${BLUE}SETTINGSBRANCH${NC} - Github branch (default: main)"
        echo -e "4. ${GREEN}Back${NC}\n"
        
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
    log "prompt" "Stats Configuration"
    echo -e "${YELLOW}Enable stats tracking to collect match data and player statistics.${NC}\n"
    echo -e "${YELLOW}Stats will automatically be submitted to https://stats.etl.lol on every round end.${NC}\n"
    
    read -p "Would you like to enable stats submission? (Y/n): " ENABLE_STATS
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
        store_setting "Stats Configuration" "STATS_API_DUMPJSON" "false"
    else
        store_setting "Stats Configuration" "STATS_SUBMIT" "false"
    fi

    log "success" "Stats collection enabled and configured!"
    sleep 1
}

configure_watchtower() {
    show_header
    log "prompt" "Watchtower Configuration"
    
    echo -e "${YELLOW}About Watchtower:${NC}"
    echo -e "• Automatically updates your ETLegacy server containers"
    echo -e "• Monitors for new versions of the server image"
    echo -e "• Performs graceful restarts when updates are available"
    echo -e "• Helps keep your servers up-to-date with latest features and fixes\n"
    
    echo -e "${BLUE}Benefits:${NC}"
    echo -e "• Automated maintenance"
    echo -e "• Always running latest version"
    echo -e "• Reduced downtime"
    echo -e "• Improved security\n"
    
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
    log "prompt" "Automatic Server Restart Configuration"
    
    echo -e "${YELLOW}About Automatic Restarts:${NC}"
    echo -e "• Helps maintain server performance"
    echo -e "• Clears memory leaks"
    echo -e "• Ensures smooth operation"
    echo -e "• Only restarts when server is empty\n"
    
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
    local default_port=$((27960 + (instance - 1) * 10))
    
    show_header
    log "prompt" "Server $instance Configuration"
    
    # Get required settings from user
    local port
    while true; do
        read -p "Server Port [default: $default_port]: " port
        port=${port:-$default_port}
        
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
            log "error" "Invalid port number. Must be between 1024 and 65535"
            continue
        fi
        break
    done
    
    # Get hostname with default
    local default_hostname="ETL-Server $instance"
    read -p "Server Name [default: $default_hostname]: " hostname
    hostname=${hostname:-"$default_hostname"}
    
    echo -e "\n${BLUE}Security Settings${NC}"
    read -p "Server Password [default: empty]: " password
    read -p "RCON Password [default: empty]: " rcon
    read -p "Referee Password [default: empty]: " referee
    read -p "Shoutcaster Password [default: empty]: " sc

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
    log "prompt" "Generating Docker Compose Configuration"

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
    log "prompt" "Creating Server Management Script"

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
    echo "Usage: $0 [start|stop|restart|status] [instance_number]"
    echo
    echo "Commands:"
    echo "  start    Start servers"
    echo "  stop     Stop servers"
    echo "  restart  Restart servers"
    echo "  status   Show server status"
    echo
    echo "Examples:"
    echo "  etl-server start     # Starts all servers"
    echo "  etl-server stop 2    # Stops server instance 2"
    echo "  etl-server restart 1 # Restarts server instance 1"
    echo "  etl-server status    # Shows status of all servers"
    echo "  etl-server status 2  # Shows status of server 2"
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

    # Print status with fixed width columns
    printf "%-12s %-18s %-15s %-8s %-10s %-12s %-12s\n" \
           "$container" \
           "$status" \
           "$hostname" \
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
    printf "%-12s %-18s %-15s %-8s %-10s %-12s %-12s\n" \
           "CONTAINER" "STATUS" "HOSTNAME" "PORT" "PASSWORD" "RCONPASS" "REFPASS"
    echo "------------------------------------------------------------------------------"
    
    if [ -n "$instance" ]; then
        get_container_status "etl-server$instance"
    else
        for container in $(docker ps -a --filter "name=etl-server" --format "{{.Names}}" | sort); do
            get_container_status "$container"
        done
    fi
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
    log "prompt" "Map Download Webserver Configuration"
    
    echo -e "${YELLOW}About Map Download Webserver:${NC}"
    echo -e "• Allows players to download missing maps directly from your server"
    echo -e "• Minimal resource usage (lightweight HTTP server)"
    echo -e "• Faster downloads for custom maps and legacy updates\n"
    
    read -p "Would you like to enable the map download webserver? (Y/n): " ENABLE_WEBSERVER
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
    
    log "info" "Performing post-deployment tasks..."
    
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
    log "prompt" "Starting ETLegacy Server Setup..."
    
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
    compose_cmd=$(detect_docker_compose_command) || {
        log "error" "Docker Compose not found. Please install Docker Compose."
        exit 1
    }
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

    setup_directory "$INSTALL_DIR/logs" "$SELECTED_USER" || exit 1
    for i in $(seq 1 $INSTANCES); do
        setup_directory "$INSTALL_DIR/logs/etl-server$i" "$SELECTED_USER" || exit 1
    done
    chmod -R 777 "$INSTALL_DIR/logs"

    create_helper_script "$INSTALL_DIR" "$INSTANCES"
    chown -R "$SELECTED_USER:$SELECTED_USER" "$INSTALL_DIR"

    show_header
        log "success" "Starting ETL servers..."

        # Check if we're using a newly created user
        if [[ $USER_OPTION == "2" ]]; then
            # For new users, start with root first time
            log "info" "Starting servers with root permissions first time..."
            cd "$INSTALL_DIR" && ./server start
        else
            # For existing users, start as the selected user
            su - "$SELECTED_USER" -c "cd $INSTALL_DIR && ./server start"
        fi

    post_deployment_tasks "$INSTALL_DIR"

    show_header 
    log "success" "Setup complete! Your ETL servers are now running..."
    log ""
    log "info" "Servers are running under user: $SELECTED_USER"
        
    if [[ $USER_OPTION == "2" ]]; then
        log "warning" "Important: For a new user, please:"
        log "info" "1. Log out of your current session"
        log "info" "2. Log in as $SELECTED_USER"
        log "info" "3. Run 'etl-server restart' to ensure proper permissions"
    fi

    log "info" "Use 'etl-server start|stop|restart|status [instance_number]' to manage your servers"
    log "info" "Or simply 'etl-server' to display the help message"
    log ""
    log "info" "Make sure to forward the necessary ports for your servers:" 

    # Get server ports from settings file
    log "info" "ETL-Server PORTS (UDP):"
    for i in $(seq 1 $INSTANCES); do
        port=$(grep "SERVER${i}_MAP_PORT=" "$SETTINGS_FILE" | cut -d'=' -f2)
        if [ ! -z "$port" ]; then
            echo -e "  - $port"
        fi
    done

    # Only show webserver URL if it was enabled
    if grep -q "^REDIRECTURL=" "$SETTINGS_FILE"; then
        redirect_url=$(grep "^REDIRECTURL=" "$SETTINGS_FILE" | cut -d'=' -f2)
        log "info" "Webserver URL:"
        echo -e "  - $redirect_url"
    fi

}

main