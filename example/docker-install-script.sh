#!/bin/bash

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
CURRENT_USER="$SUDO_USER"

[ -z "$CURRENT_USER" ] && CURRENT_USER="$USER"

SETTINGS_FILE="settings.env"
DEFAULT_MAPS="adlernest braundorf_b4 "

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

trap 'handle_error ${LINENO} $?' ERR
set -euo pipefail

prompt_with_default() {
    local prompt=$1
    local default=$2
    local help_text="${3:-}"
    
    # Show help text if provided
    if [ ! -z "$help_text" ]; then
        echo -e "${YELLOW}${help_text}${NC}\n"
    fi
    
    echo -e "${CYAN}${prompt}${NC}"
    echo -e "${BLUE}Default: ${BOLD}${default}${NC}\n"
    read -p "> " value
    echo "${value:-$default}"
}

add_setting() {
    local category=$1
    local key=$2
    local value=$3
    
    # Create temp file
    local temp_file=$(mktemp)
    
    # If file is empty, initialize it
    if [ ! -s "$SETTINGS_FILE" ]; then
        initialize_settings_file "$INSTALL_DIR" "$CURRENT_USER"
    fi
    
    # Determine the correct category based on key prefix
    if [[ $key == STATS_* ]]; then
        category="Stats Configuration"
    elif [[ $key == SERVER[0-9]_* ]]; then
        category="Server Configurations"
    elif [[ $key == "LOGS" || $key == "MAPSDIR" ]]; then
        category="Volumes"
    elif [[ $key == "MAPS" ]]; then
        category="Map Settings"
    else
        category="Additional Settings"
    fi
    
    local in_correct_section=false
    local setting_written=false
    local current_section=""
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Handle section headers
        if [[ $line =~ ^#[[:space:]]*(.*)[[:space:]]*$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            echo "$line" >> "$temp_file"
            
            if [ "$current_section" = "$category" ] && [ "$setting_written" = false ]; then
                # For server configurations, group by instance
                if [[ $key =~ ^SERVER([0-9]+)_ ]]; then
                    local instance="${BASH_REMATCH[1]}"
                    # Only add if we haven't already written this server's settings
                    if ! grep -q "^# ETL Server \".*\" ($instance)$" "$temp_file"; then
                        echo -e "\n# ETL Server \"$hostname\" ($instance)" >> "$temp_file"
                        echo "$key=$value" >> "$temp_file"
                        setting_written=true
                    fi
                else
                    echo "$key=$value" >> "$temp_file"
                    setting_written=true
                fi
            fi
            continue
        fi
        
        # Skip existing setting if we're updating it
        if [[ $line =~ ^$key= ]]; then
            continue
        fi
        
        echo "$line" >> "$temp_file"
    done < "$SETTINGS_FILE"
    
    # If setting wasn't written, add it to the appropriate section
    if [ "$setting_written" = false ]; then
        if ! grep -q "^# $category$" "$temp_file"; then
            echo -e "\n# $category" >> "$temp_file"
        fi
        
        if [[ $key =~ ^SERVER([0-9]+)_ ]]; then
            local instance="${BASH_REMATCH[1]}"
            echo -e "\n# ETL Server \"$hostname\" ($instance)" >> "$temp_file"
        fi
        echo "$key=$value" >> "$temp_file"
    fi
    
    mv "$temp_file" "$SETTINGS_FILE"
    chmod 644 "$SETTINGS_FILE"
}

# Function to show info with auto-skip or forced input
show_info_with_timeout() {
    local message="$1"
    local force_input="${2:-false}"  # Default to false if not provided
    local default_value="${3:-}"     # Empty string if not provided
    local prompt_symbol="${4:->}"    # Default to ">" if not provided
    local timeout=5
    local input=""
    
    echo -e "$message"
    
    if [ "$force_input" = "true" ]; then
        echo -e "\n${YELLOW}Enter your response:${NC}"
        read -p "$prompt_symbol " input
        echo "${input:-$default_value}"
        return 0
    fi
    
    if [ -n "$default_value" ]; then
        echo -e "\n${YELLOW}Enter response or wait ${timeout} seconds for default: ${BLUE}$default_value${NC}"
    else
        echo -e "\n${YELLOW}Press Enter to continue or wait ${timeout} seconds${NC}"
    fi
    
    # Start timeout read with countdown
    while [ $timeout -gt 0 ]; do
        echo -en "\r${BLUE}$timeout${NC} seconds..."
        if read -t 1 -n 1 input; then
            echo
            [ -n "$input" ] && echo "$input" || echo "$default_value"
            return 0
        fi
        ((timeout--))
    done
    
    # If we get here, the timeout occurred
    echo -e "\r${GREEN}Continuing...     ${NC}"
    [ -n "$default_value" ] && echo "$default_value"
    
    # Clear any pending input
    read -t 0.1 -n 100 input 2>/dev/null || true  
    echo -en "\r\033[K"  # Clear the current line
    return 0
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

initialize_settings_file() {
    local install_dir="$1"
    local current_user="$2"
    local settings_file="$install_dir/settings.env"
    local current_date=$(date -u +"%Y-%m-%d %H:%M:%S")
    
    cat > "$settings_file" << EOL
# ETLegacy Server Configuration
# Generated on $current_date UTC
# Created by $current_user

# Using version 'stable' for etlegacy. For more available builds see: https://hub.docker.com/repository/docker/oksii/etlegacy/tags
VERSION=stable

# Volumes

# Map Settings

# Stats Configuration

# Additional Settings

# Server Configurations

EOL

    # Set proper ownership
    if ! chown "$SELECTED_USER:$SELECTED_USER" "$settings_file"; then
        log "error" "Failed to set ownership of $settings_file"
        return 1
    fi
    
    return 0
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
    if ! command -v lsb_release >/dev/null 2>&1; then
        log "info" "Installing lsb-release..."
        apt-get update &>/dev/null && apt-get install -y lsb-release &>/dev/null
    fi
    
    local os_id=$(lsb_release -si)
    local os_version=$(lsb_release -sr)
    
    if [[ ! "$os_id" =~ ^(Ubuntu|Debian)$ ]]; then
        log "error" "This script only supports Ubuntu and Debian systems."
        log "error" "Detected system: $os_id $os_version"
        exit 1
    fi
    
    log "success" "System compatibility check passed ($os_id $os_version)"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log "error" "This script must be run as root or with sudo."
        exit 1
    fi
}

check_resources() {
    show_header
    log "prompt" "Checking System Resources..."
    
    local cpu_cores=$(nproc)
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local disk_space=$(df -m "$HOME" | awk 'NR==2 {print $4}')
    
    echo -e "${BLUE}CPU Cores:${NC} $cpu_cores"
    echo -e "${BLUE}Total Memory:${NC} $total_mem MB"
    echo -e "${BLUE}Available Disk Space:${NC} $disk_space MB\n"
    
    local warnings=()
    [ "$cpu_cores" -lt 2 ] && warnings+=("Low CPU cores detected (minimum recommended: 2)")
    [ "$total_mem" -lt 1024 ] && warnings+=("Low memory detected (minimum recommended: 1GB)")
    [ "$disk_space" -lt 2048 ] && warnings+=("Low disk space detected (minimum recommended: 2GB)")
    
    if [ ${#warnings[@]} -gt 0 ]; then
        log "warning" "Resource Warnings:"
        for warning in "${warnings[@]}"; do
            echo -e "${YELLOW}• $warning${NC}"
        done
        show_info_with_timeout "Review the warnings above." "true" || true 
    else
        log "success" "System resources look good!"
        show_info_with_timeout "All resource checks passed." || true 
    fi
    
    return 0 
}

install_requirements() {
    show_header
    log "prompt" "Installing Required Packages..."
    
    local packages=(
        curl
        wget
        parallel
        lsb-release
        gnupg
        ca-certificates
        apt-transport-https
    )
    
    apt-get update &>/dev/null
    for package in "${packages[@]}"; do
        echo -n "Installing $package... "
        if apt-get install -y "$package" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            log "error" "Failed to install $package"
            return 1
        fi
    done
    
    log "success" "All required packages installed successfully!"
    sleep 2
}

setup_user() {
    show_header
    log "prompt" "User Account Setup"
    
    SELECTED_USER=""
    local current_user="$SUDO_USER"
    [ -z "$current_user" ] && current_user="$USER"
    local default_server_user="etlserver"
    
    # Check if current user is a regular user (UID 1000)
    local current_uid=$(id -u "$current_user")
    local suggested_option="2"  # Default to creating new user
    
    if [ "$current_uid" = "1000" ]; then
        suggested_option="1"  # Suggest using current user if it's UID 1000
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
                    local new_user=$(prompt_with_default "Enter username for new account" "$default_server_user" "Username for the new system account")
                    
                    # Check if user already exists
                    if id "$new_user" >/dev/null 2>&1; then
                        log "warning" "User '$new_user' already exists. Please choose a different username."
                        continue
                    fi
                    
                    # Validate username format
                    if ! [[ $new_user =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
                        log "warning" "Invalid username format. Use only lowercase letters, numbers, dash (-) and underscore (_)."
                        continue
                    fi
                    
                    echo -e "\n${YELLOW}Creating user account...${NC}"
                    if useradd -m -s /bin/bash "$new_user"; then
                        echo -e "\n${YELLOW}Please set a password for $new_user${NC}"
                        if passwd "$new_user"; then
                            SELECTED_USER=$new_user
                            break 2 
                        else
                            log "error" "Failed to set password. Removing user..."
                            userdel -r "$new_user" >/dev/null 2>&1
                        fi
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

check_docker() {
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null || command -v docker-compose &> /dev/null; then
            return 0
        else
            return 2
        fi
    else
        return 1
    fi
}

install_docker() {
    show_header
    log "prompt" "Docker Installation"
    
    local docker_status
    check_docker
    docker_status=$?
    
    case $docker_status in
        0)
            log "success" "Docker and Docker Compose are already installed."
            read -p "Would you like to reinstall official Docker packages? (y/N): " REINSTALL
            [[ $REINSTALL =~ ^[Yy]$ ]] && perform_docker_install
            ;;
        1)
            log "info" "Docker not found. Installing official Docker packages..."
            perform_docker_install
            ;;
        2)
            log "warning" "Docker is installed but Docker Compose is missing."
            read -p "Would you like to install Docker Compose? (Y/n): " INSTALL_COMPOSE
            if [[ ! $INSTALL_COMPOSE =~ ^[Nn]$ ]]; then
                apt-get update &>/dev/null
                apt-get install -y docker-compose-plugin &>/dev/null
            else
                log "error" "Docker Compose is required for this setup."
                exit 1
            fi
            ;;
    esac
    
    # Ensure user is in docker group
    groupadd -f docker
    usermod -aG docker "$SELECTED_USER"
    
    # Start and enable Docker service
    systemctl start docker || {
        log "error" "Failed to start Docker service"
        exit 1
    }
    systemctl enable docker || {
        log "error" "Failed to enable Docker service"
        exit 1
    }
    
    log "success" "Docker setup complete!"
    log "info" "Note: You'll need to log out and back in for docker group membership to take effect."
    sleep 3
    show_header
    return 0
}

perform_docker_install() {
    log "info" "Installing Docker..."
    echo -e "${YELLOW}This may take a minute...${NC}\n"
    
    local tmp_log=$(mktemp)
    local os_id=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    local os_codename=$(lsb_release -sc)
    
    echo -n "Installing prerequisites... "
    if apt-get update &> "$tmp_log" && \
       apt-get install -y \
       ca-certificates \
       curl \
       gnupg \
       lsb-release \
       parallel &>> "$tmp_log"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        cat "$tmp_log"
        rm "$tmp_log"
        return 1
    fi
    
    echo -n "Adding Docker repository... "
    if mkdir -p /etc/apt/keyrings && \
       case "$os_id" in
           ubuntu|debian)
               # Download the correct GPG key and repo URL based on OS
               curl -fsSL "https://download.docker.com/linux/$os_id/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg &>> "$tmp_log" && \
               echo \
               "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$os_id \
               $os_codename stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
               ;;
           *)
               echo -e "${RED}Unsupported operating system: $os_id${NC}"
               rm "$tmp_log"
               return 1
               ;;
       esac; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        cat "$tmp_log"
        rm "$tmp_log"
        return 1
    fi
    
    echo -n "Installing Docker packages... "
    if apt-get update &>> "$tmp_log" && \
       apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin &>> "$tmp_log"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        cat "$tmp_log"
        rm "$tmp_log"
        return 1
    fi
    
    rm "$tmp_log"
    log "success" "Docker installation completed successfully!"
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
    
    setup_directory "$install_dir/maps" "$SELECTED_USER" || return 1
    
    show_header
    log "prompt" "Map Repository Selection"
    echo -e "1. ${BLUE}dl.etl.lol${NC}"
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
    echo -e "${BLUE}Examples of additional maps:${NC}"
    echo -e "• etl_base, mp_sillyctf"
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
    
    > "$maps_txt"
    > "$failed_maps"
    local maps_env=""
    
    for map in $maplist; do
        map=$(check_pk3 "$map")
        echo "$map" >> "$maps_txt"
        map_name=$(basename "$map" ".pk3")
        maps_env="${maps_env}${map_name}:"
    done
    
    # Write maps to settings file
    add_setting "Map Settings" "MAPS" "${maps_env%:}"

    log "info" "Starting map downloads from $repo_url..."
    echo "This may take a while. Maps will be downloaded in parallel."

    parallel --eta --jobs 30 --progress \
        "wget -q -P \"$install_dir/maps\" \"$repo_url/{}\" 2>/dev/null || 
        echo {} >> \"$failed_maps\"; 
        echo \"Downloaded: {}\"" \
        :::: "$maps_txt" | \
        while IFS= read -r line; do
            if [[ $line == Downloaded:* ]]; then
                echo -e "${GREEN}✓${NC} ${line#Downloaded: }"
            fi
        done
    
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
    sleep 2
    
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
    
    echo "MAPS=$maps_env" >> $SETTINGS_FILE
    echo "REDIRECTURL=https://download.hirntot.org" >> $SETTINGS_FILE
    
    log "success" "Map download configuration completed!"
    sleep 2
}

configure_additional_variables() {
    local instances=$1
    
    while true; do
        show_header
        log "prompt" "Additional Configuration Options"
        echo -e "The following settings are optional. Default values will be used if skipped.\n"
        
        echo -e "1. ${BLUE}STARTMAP${NC} - Starting map (default: radar)"
        echo -e "2. ${BLUE}MAXCLIENTS${NC} - Maximum players (default: 32)"
        echo -e "3. ${BLUE}AUTO_UPDATE${NC} - Auto-update configs (default: true)"
        echo -e "4. ${BLUE}SETTINGSURL${NC} - Config repository URL"
        echo -e "5. ${BLUE}Advanced Options${NC} - Additional settings"
        echo -e "6. ${GREEN}Done${NC}\n"
        
        read -p "Select option (1-6) [default: 6]: " option
        option=${option:-6}
        case $option in
            1)
                show_header
                log "prompt" "STARTMAP Configuration"
                echo -e "${YELLOW}The starting map is the map that loads when the server starts.${NC}\n"
                read -p "Configure STARTMAP globally or per-server? (G/s): " scope
                if [[ $scope =~ ^[Ss]$ ]]; then
                    for i in $(seq 1 $instances); do
                        local startmap=$(prompt_with_default "Enter STARTMAP for server$i" "radar" "This map will be loaded when server$i starts.")
                        echo "SERVER${i}_STARTMAP=$startmap" >> $SETTINGS_FILE
                    done
                else
                    local startmap=$(prompt_with_default "Enter global STARTMAP" "radar" "This map will be loaded when any server starts.")
                    echo "STARTMAP=$startmap" >> $SETTINGS_FILE
                fi
                ;;
            2)
                show_header
                log "prompt" "MAXCLIENTS Configuration"
                echo -e "${YELLOW}Maximum number of players that can connect to the server.${NC}\n"
                read -p "Configure MAXCLIENTS globally or per-server? (G/s): " scope
                if [[ $scope =~ ^[Ss]$ ]]; then
                    for i in $(seq 1 $instances); do
                        local maxclients=$(prompt_with_default "Enter MAXCLIENTS for server$i" "32" "Maximum players allowed on server$i.")
                        echo "SERVER${i}_MAXCLIENTS=$maxclients" >> $SETTINGS_FILE
                    done
                else
                    local maxclients=$(prompt_with_default "Enter global MAXCLIENTS" "32" "Maximum players allowed on all servers.")
                    echo "MAXCLIENTS=$maxclients" >> $SETTINGS_FILE
                fi
                ;;
            3)
                show_header
                log "prompt" "AUTO_UPDATE Configuration"
                echo -e "${YELLOW}Enable automatic updates of server configurations on restart?${NC}\n"
                local autoupdate=$(prompt_with_default "Enable AUTO_UPDATE" "true" "Set to 'false' to disable automatic updates.")
                echo "AUTO_UPDATE=$autoupdate" >> $SETTINGS_FILE
                ;;
            4)
                show_header
                log "prompt" "SETTINGSURL Configuration"
                echo -e "${YELLOW}URL for the Git repository containing server configurations.${NC}\n"
                local settingsurl=$(prompt_with_default "Enter SETTINGSURL" "https://github.com/Oksii/legacy-configs.git" "Public Git repository URL for server configurations.")
                echo "SETTINGSURL=$settingsurl" >> $SETTINGS_FILE
                ;;
            5)
                configure_advanced_options "$instances"
                ;;
            6)
                break
                ;;
            *)
                log "warning" "Invalid option"
                sleep 1
                ;;
        esac
    done
}

configure_advanced_options() {
    local instances=$1
    
    while true; do
        show_header
        log "prompt" "Advanced Configuration Options"
        echo -e "${YELLOW}Warning: These settings are for advanced users. Use default values if unsure.${NC}\n"
        
        echo -e "1. ${BLUE}SVTRACKER${NC} - Server tracker endpoint"
        echo -e "2. ${BLUE}XMAS${NC} - Enable XMAS mode"
        echo -e "3. ${BLUE}SETTINGSBRANCH${NC} - Git branch for configs"
        echo -e "4. ${BLUE}ADDITIONAL_CLI_ARGS${NC} - Additional command line arguments"
        echo -e "5. ${GREEN}Back to main menu${NC}\n"
        
        read -p "Select option (1-5) [default: 5]: " option
        option=${option:-5}
        case $option in
            1)
                local tracker=$(prompt_with_default "Enter SVTRACKER endpoint" "tracker.etl.lol:4444" "Server tracking service endpoint.")
                echo "SVTRACKER=$tracker" >> $SETTINGS_FILE
                ;;
            2)
                show_header
                log "prompt" "XMAS Configuration"
                echo -e "${YELLOW}Enable Christmas themed content?${NC}\n"
                read -p "Enable XMAS mode? (y/N): " ENABLE_XMAS
                if [[ $ENABLE_XMAS =~ ^[Yy]$ ]]; then
                    echo "XMAS=true" >> $SETTINGS_FILE
                    local xmas_url=$(prompt_with_default "Enter XMAS_URL" "" "URL for downloading xmas.pk3 (leave empty for default)")
                    [ ! -z "$xmas_url" ] && echo "XMAS_URL=$xmas_url" >> $SETTINGS_FILE
                fi
                ;;
            3)
                local branch=$(prompt_with_default "Enter SETTINGSBRANCH" "main" "Git branch for server configurations.")
                echo "SETTINGSBRANCH=$branch" >> $SETTINGS_FILE
                ;;
            4)
                show_header
                log "prompt" "Additional Command Line Arguments"
                echo -e "${YELLOW}Specify additional arguments to pass to the server.${NC}"
                echo -e "${YELLOW}Example: +set sv_tracker \"et.trackbase.com:4444\" +set sv_autodemo 2${NC}\n"
                read -p "Enter additional arguments: " cli_args
                [ ! -z "$cli_args" ] && echo "ADDITIONAL_CLI_ARGS=\"$cli_args\"" >> $SETTINGS_FILE
                ;;
            5) return 0 ;;
            *) log "warning" "Invalid option" ;;
        esac
    done
}

setup_stats_variables() {
    show_header
    log "prompt" "Stats Configuration"
    echo -e "${YELLOW}Enable stats tracking to collect match data and player statistics.${NC}\n"
    
    read -p "Would you like to enable stats submission? (Y/n): " ENABLE_STATS
    if [[ ! $ENABLE_STATS =~ ^[Nn]$ ]]; then
        add_setting "Stats Configuration" "STATS_SUBMIT" "true"
        add_setting "Stats Configuration" "STATS_API_TOKEN" "GameStatsWebLuaToken"
        add_setting "Stats Configuration" "STATS_API_URL_SUBMIT" "https://api.etl.lol/api/v2/stats/etl/matches/stats/submit"
        add_setting "Stats Configuration" "STATS_API_URL_MATCHID" "https://api.etl.lol/api/v2/stats/etl/match-manager"
        add_setting "Stats Configuration" "STATS_API_PATH" "/legacy/homepath/legacy/stats"
        add_setting "Stats Configuration" "STATS_API_LOG" "false"
        add_setting "Stats Configuration" "STATS_API_OBITUARIES" "false"
        add_setting "Stats Configuration" "STATS_API_DAMAGESTAT" "false"
        add_setting "Stats Configuration" "STATS_API_MESSAGELOG" "false"
        add_setting "Stats Configuration" "STATS_API_DUMPJSON" "false"
    else
        add_setting "Stats Configuration" "STATS_SUBMIT" "false"
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
    
    sleep 2
    return 0
}

# Add Watchtower service to docker-compose
add_watchtower_service() {
    cat >> docker-compose.yml << 'EOL'

  watchtower:
    container_name: watchtower
    image: containrrr/watchtower
    command: --enable-lifecycle-hooks
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


# Generate individual server service configurations
generate_service() {
    local instance=$1
    local default_port=$((27960 + instance - 1))
    
    show_header
    log "prompt" "Server $instance Configuration"
    
    echo -e "${YELLOW}Configure ETL Server $instance${NC}\n"
    
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
    
    read -p "Server Name [default: ^7ETL Server $instance]: " hostname
    hostname=${hostname:-"^7ETL Server $instance"}
    
    echo -e "\n${BLUE}Security Settings${NC}"
    read -p "Server Password [default: empty]: " password
    read -p "RCON Password [default: empty]: " rcon
    read -p "Referee Password [default: empty]: " referee
    read -p "Shoutcaster Password [default: empty]: " sc

    {
        echo "# ETL Server \"$hostname\""
        echo "SERVER${instance}_HOSTNAME=$hostname"
        echo "SERVER${instance}_PORT=$port"
        [ ! -z "$password" ] && echo "SERVER${instance}_PASSWORD=$password"
        [ ! -z "$rcon" ] && echo "SERVER${instance}_RCONPASSWORD=$rcon"
        [ ! -z "$referee" ] && echo "SERVER${instance}_REFEREEPASSWORD=$referee"
        [ ! -z "$sc" ] && echo "SERVER${instance}_SCPASSWORD=$sc"
        echo ""
    } >> "$SETTINGS_FILE"
    
    cat >> docker-compose.yml << EOL

  etl-server$instance:
    <<: *common-core
    container_name: etl-server$instance
    environment:
      MAP_PORT: \${SERVER${instance}_PORT}
      HOSTNAME: \${SERVER${instance}_HOSTNAME}
EOL

    [ ! -z "$password" ] && echo "      PASSWORD: \${SERVER${instance}_PASSWORD}" >> docker-compose.yml
    [ ! -z "$rcon" ] && echo "      RCONPASSWORD: \${SERVER${instance}_RCONPASSWORD}" >> docker-compose.yml
    [ ! -z "$referee" ] && echo "      REFEREEPASSWORD: \${SERVER${instance}_REFEREEPASSWORD}" >> docker-compose.yml
    [ ! -z "$sc" ] && echo "      SCPASSWORD: \${SERVER${instance}_SCPASSWORD}" >> docker-compose.yml

    cat >> docker-compose.yml << EOL
    volumes:
      - "\${MAPSDIR}:/maps"
      - "\${LOGS}/etl-server$instance:/legacy/homepath/legacy/"
    ports:
      - '\${SERVER${instance}_PORT}:\${SERVER${instance}_PORT}/udp'
EOL

    setup_directory "$INSTALL_DIR/logs/etl-server$instance" "$SELECTED_USER" || return 1
    log "success" "Server $instance configuration complete"
    sleep 1
}

generate_docker_compose() {
    local install_dir=$1
    local instances=$2
    local use_watchtower=$3

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
        log "success" "Server $i configuration complete!"
    done

    # Add Watchtower service if enabled
    if [[ $use_watchtower =~ ^[Yy]$ ]]; then
        log "info" "Adding Watchtower service for automatic updates..."
        add_watchtower_service
    fi

    log "success" "Docker Compose configuration generated successfully!"
    sleep 2
}

setup_volume_paths() {
    local install_dir="$1"
    add_setting "Volumes" "MAPSDIR" "$install_dir/maps"
    add_setting "Volumes" "LOGS" "$install_dir/logs"
}

create_helper_script() {
    local install_dir="$1"
    local instances="$2"
    
    show_header
    log "prompt" "Creating Server Management Script"
    
    cat > "$install_dir/server" << EOL
#!/bin/bash
INSTALL_DIR="$install_dir"
SETTINGS_FILE="\$INSTALL_DIR/settings.env"
cd "\$INSTALL_DIR" || exit 1

usage() {
    echo "ETLegacy Server Management Script"
    echo "================================"
    echo "Usage: \$0 [start|stop|restart] [instance_number]"
    echo
    echo "Commands:"
    echo "  start    Start servers"
    echo "  stop     Stop servers"
    echo "  restart  Restart servers"
    echo
    echo "Examples:"
    echo "  \$0 start     # Starts all servers"
    echo "  \$0 stop 2    # Stops server instance 2"
    echo "  \$0 restart 1 # Restarts server instance 1"
    exit 1
}

if [ \$# -lt 1 ]; then
    usage
fi

ACTION=\$1
INSTANCE=\$2

case \$ACTION in
    start)
        if [ -z "\$INSTANCE" ]; then
            echo "Starting all servers..."
            docker compose --env-file=\$SETTINGS_FILE up -d
        else
            echo "Starting server \$INSTANCE..."
            docker compose --env-file=\$SETTINGS_FILE up -d etl-server\$INSTANCE
        fi
        ;;
    stop)
        if [ -z "\$INSTANCE" ]; then
            echo "Stopping all servers..."
            docker compose --env-file=\$SETTINGS_FILE down
        else
            echo "Stopping server \$INSTANCE..."
            docker compose --env-file=\$SETTINGS_FILE stop etl-server\$INSTANCE
        fi
        ;;
    restart)
        if [ -z "\$INSTANCE" ]; then
            echo "Restarting all servers..."
            docker compose --env-file=\$SETTINGS_FILE restart
        else
            echo "Restarting server \$INSTANCE..."
            docker compose --env-file=\$SETTINGS_FILE restart etl-server\$INSTANCE
        fi
        ;;
    *)
        usage
        ;;
esac
EOL

    chmod +x "$install_dir/server"
    chown "$SELECTED_USER:$SELECTED_USER" "$install_dir/server"
    ln -sf "$install_dir/server" /usr/local/bin/etl-server
    
    log "success" "Server management script created!"
    sleep 2
}

review_settings() {
    show_header
    log "prompt" "Configuration Review"
    
    echo -e "${BLUE}Installation Directory:${NC} $INSTALL_DIR"
    echo -e "${BLUE}Number of Instances:${NC} $INSTANCES\n"

    display_section() {
        local section=$1
        local content
        
        echo -e "\n${YELLOW}# $section${NC}"
        content=$(sed -n "/^# $section$/,/^#/p" "$SETTINGS_FILE" | grep "^[A-Z]" || true)
        if [ ! -z "$content" ]; then
            echo -e "$content" | sort
        fi
    }
    
    display_section "Volumes"
    display_section "Map Settings"
    display_section "Stats Configuration"
    display_section "Additional Settings"
    
    echo -e "\n${YELLOW}# Server Configurations${NC}"
    for i in $(seq 1 $INSTANCES); do
        # Find and display each server's configuration
        if grep -q "^# ETL Server \".*\"$" "$SETTINGS_FILE"; then
            server_name=$(sed -n "/^# ETL Server \".*\"$/,/^#/p" "$SETTINGS_FILE" | grep "SERVER${i}_HOSTNAME" | cut -d'=' -f2- || true)
            if [ ! -z "$server_name" ]; then
                echo -e "\n${BLUE}# ETL Server \"$server_name\"${NC}"
                sed -n "/^# ETL Server \".*\"$/,/^#/p" "$SETTINGS_FILE" | grep "^SERVER${i}_" | sort || true
            fi
        fi
    done
    
    # Show Docker configuration with proper escaping of $ signs
    echo -e "\n${BLUE}Docker Compose Configuration:${NC}"
    echo -e "${YELLOW}"
    sed 's/\$/\\\$/g' docker-compose.yml || true
    echo -e "${NC}"
    
    echo
    read -p "Press Enter to continue with these settings, or Ctrl+C to abort..."
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
    check_resources
    install_requirements || exit 1
    setup_user || exit 1
    
    if [ -z "$SELECTED_USER" ]; then
        log "error" "No user was selected during setup"
        exit 1
    fi

    setup_installation_directory "$SELECTED_USER" || {
        log "error" "Failed to setup installation directory"
        exit 1
    }
    
    if [ -z "$INSTALL_DIR" ]; then
        log "error" "Installation directory was not set"
        exit 1
    fi

    # Set up settings file path
    export SETTINGS_FILE="$INSTALL_DIR/settings.env"

    # Initialize settings file
    initialize_settings_file "$INSTALL_DIR" "$CURRENT_USER" || {
        log "error" "Failed to initialize settings file"
        exit 1
    }

    install_docker || exit 1
    
    cd "$INSTALL_DIR" || {
        log "error" "Failed to change to installation directory"
        exit 1
    }

    configure_server_instances
    setup_maps "$INSTALL_DIR"
    setup_map_environment
    setup_stats_variables
    configure_additional_variables "$INSTANCES"
    setup_volume_paths "$INSTALL_DIR"
    configure_watchtower
    configure_auto_restart || true 

    generate_docker_compose "$INSTALL_DIR" "$INSTANCES" "$USE_WATCHTOWER"

    read -p "Would you like to review your settings? (Y/n): " REVIEW
    if [[ ! $REVIEW =~ ^[Nn]$ ]]; then
        review_settings
    fi

    setup_directory "$INSTALL_DIR/logs" "$SELECTED_USER" || exit 1
    for i in $(seq 1 $INSTANCES); do
        setup_directory "$INSTALL_DIR/logs/etl-server$i" "$SELECTED_USER" || exit 1
    done
    chmod -R 777 "$INSTALL_DIR/logs"

    create_helper_script "$INSTALL_DIR" "$INSTANCES"

    chown -R "$SELECTED_USER:$SELECTED_USER" "$INSTALL_DIR"

    show_header
    log "success" "Setup complete! Your ETL servers are now being started..."
    log ""
    log "info" "Servers are running under user: $SELECTED_USER"
    log "info" "Use 'etl-server start|stop|restart [instance_number]' to manage your servers"
    log ""
    log "warning" "Please log out and back in as $SELECTED_USER for docker group membership to take effect"

    su - "$SELECTED_USER" -c "cd $INSTALL_DIR && ./server start"
}

main