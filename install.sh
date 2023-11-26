#!/bin/bash
#
# Hyperion installation script.
#
# This script is meant for quick & easy install via:
#   'curl -sSL https://releases.hyperion-project.org/install | bash'
# or:
#   'wget -qO- https://releases.hyperion-project.org/install | bash'
#

# Default values

# Nightly prefix
_NIGHTLY=""
# Switch to install or remove
_REMOVE=false
# Verbose output
_VERBOSE=false
#Distribution
_DISTRO=""
# Alternate codebase
_CODEBASE=""
# Package repository uri
_BASE_REPO_URI="releases.hyperion-project.org"

# Help print function
function printHelp {
  cat <<EOL
The script allows installing and removing Hyperion.

Options:
  -n, --nightly       Install the nightly build
  -u, --ubuntu        Use an alternate codebase for Ubuntu derivatives, e.g., use "jammy" for Pop!_OS 22.04 LTS or Mint 21.2 Victoria
  -d, --debian        Use an alternate codebase for Debian derivatives
  -f, --fedora        Use an alternate codebase for Fedora derivatives
  -r, --remove        Remove an existing Hyperion installation
  -v, --verbose       Run the script in verbose mode
  -h, --help          Show this help message
EOL
}

function debug() {
  if ${_VERBOSE}; then
    echo "DEBUG: $@"
  fi
}

function info() {
  echo "INFO : $@"
}

# Print a message to stderr and exit with an error code
function error() {
  echo "ERROR: $@" >&2
  exit 1
}

function prompt() {
  while true; do
    read -p "$1 " yn
    case "${yn,,}" in
      [yes]* ) return 1;;
      [no]* ) return 0;;
      * ) echo "Please answer Yes or No.";;
    esac
  done
}

function get_architecture() {
  # Determine the current architecture
  CURRENT_ARCHITECTURE=$(uname -m)

  # Test if multiarchitecture setup, i.e., user-space is 32-bit
  if [ "${CURRENT_ARCHITECTURE}" == "aarch64" ]; then
    CURRENT_ARCHITECTURE="arm64"
    USER_ARCHITECTURE=${CURRENT_ARCHITECTURE}
    IS_V7L=$(grep -m1 -c v7l /proc/$$/maps)
    if [ $IS_V7L -ne 0 ]; then
      USER_ARCHITECTURE="armv7"
    else
      IS_V6L=$(grep -m1 -c v6l /proc/$$/maps)
      if [ $IS_V6L -ne 0 ]; then
        USER_ARCHITECTURE="armv6"
      fi
    fi
    if [ "$ARCHITECTURE" != "$USER_ARCHITECTURE" ]; then
      CURRENT_ARCHITECTURE=$USER_ARCHITECTURE
    fi
  else
    CURRENT_ARCHITECTURE=${CURRENT_ARCHITECTURE//x86_/amd}
  fi
  echo "${CURRENT_ARCHITECTURE}"
}

check_architecture() {
  # Checks if the current architecture is supported
  distro="$1"; shift

  valid_architectures=''
  case "$distro" in
    debian|ubuntu|raspbian)
      valid_architectures='armv6l, armv7l, arm64, amd64';
      ;;
    fedora)
      valid_architectures='amd64';
      ;;
    *)
      error "Unsupported distribution: ${distro}. You might need to run the script providing your underlying distribution, i.e. ubuntu, debian or fedora and its codebase."
      ;;
  esac

  current_architecture=$(get_architecture)
  debug "Current architecture: ${current_architecture}"

  echo "${valid_architectures}" | grep -qw "${current_architecture}"

  if [ $? -ne 0 ]; then
    error "Only ${valid_architectures} architecture(s) are supported for ${distro}. You are running on ${current_architecture}"
  fi

  return 0
}

function get_distro() {
  # Determine the used Linux distribution.
  distro=$(lsb_release -si 2>/dev/null || cat /etc/os-release | grep -oP '^ID=["\"]?\K\w+' || echo "unknown")
  echo ${distro} | tr '[:upper:]' '[:lower:]'
}

# Adds a 'sudo' prefix if sudo is available to execute the given command
# If not, the given command is run as is
# When requesting root permission, always show the command and never re-use cached credentials.
function sudocmd() {
  reason="$1"; shift
  if command -v sudo >/dev/null; then
    echo
    echo "About to use 'sudo' to run the following command as root:"
    echo "    $@"
    echo "in order to $reason."
    echo
    sudo "$@"
  else
    "$@"
  fi
}

# Attempts an install on Debian/Ubuntu via apt, if possible
function install_deb_package() {
  debug "Start installation via Debian package ${_NIGHTLY}"
  info "Installing dependencies..."
  apt_get_install_pkgs gpg apt-transport-https

  info "Integrate Repository..."
  DOWNLOAD_GPG_KEY="mkdir -p '/etc/apt/keyrings/' && curl --silent --show-error --location "https://${_BASE_REPO_URI}/hyperion.pub.key" | gpg --dearmor --batch --yes -o /etc/apt/keyrings/hyperion.pub.gpg"
  if ! sudocmd "download public gpg key from Hyperion Project repository" sh -c "$DOWNLOAD_GPG_KEY"; then
    error "Failed to download the public key from the Hyperion Project Repository. Please run 'apt-get update' and try again."
  fi

  suites=$(lsb_release -cs)
  if [ -n "${_CODEBASE}" ]; then
    info "Overwrite identified codebase \"${suites}\" with \"${_CODEBASE}\""
    suites=${_CODEBASE}
  fi

  architectures="$(get_architecture)"
  DEB822="X-Repolib Name: Hyperion
Enabled: yes
Types: deb
URIs: https://${_NIGHTLY}apt.${_BASE_REPO_URI}
Components: main
Suites: ${suites}
Architectures: ${architectures}
Signed-By: /etc/apt/keyrings/hyperion.pub.gpg"

  if ! sudocmd "add Hyperion Project repository to the system" tee "/etc/apt/sources.list.d/hyperion.${_NIGHTLY}sources" <<< "$DEB822"; then
    error "Failed to add the Hyperion Project Repository. Please run 'apt-get update' and try again."
  fi

  info "Install Hyperion..."
  info ""
  if ! sudocmd "install hyperion" sh -c "apt-get update && apt-get -y install hyperion"; then
    error "Failed to install Hyperion. Please run 'apt-get update' and try again."
  fi
}

# Attempts an uninstall on Debian/Ubuntu via apt, if possible
function uninstall_deb_package() {
  debug "Start uninstall via Debian package"

  info "Uninstall Hyperion..."
  info ""
  if ! sudocmd "uninstall hyperion" sh -c "apt-get --purge autoremove hyperion"; then
    error "Failed to uninstall Hyperion. Please try again."
  fi

  if ! sudocmd "remove the Hyperion-Project APT source from your system" sh -c "rm -f /usr/share/keyrings/hyperion.pub.gpg /etc/apt/sources.list.d/hyperion.${_NIGHTLY}sources"; then
    error "Failed to remove the Hyperion Project Repository. Please check the log for any errors."
  fi
}

# Attempts an install on Fedora via dnf, if possible
function install_dnf_package() {
  debug "Start installation via DNF package ${_NIGHTLY}"
  info "Installing dependencies..."
  info ""
  if ! sudocmd "install required system dependencies" dnf -q install -y dnf-plugins-core; then
    error "Failed to install required system dependencies. Please run 'dnf check-update' and try again."
  fi

  info "Integrate Hyperion Project Repository..."
  info ""
  if ! sudocmd "add Hyperion Project repository to the system:" dnf -q -y config-manager --add-repo https://${_NIGHTLY}dnf.${_BASE_REPO_URI}/fedora/hyperion.repo; then
    error "Failed to add the Hyperion Project Repository. Please run 'dnf check-update' and try again."
  fi

  if [ -n "${_CODEBASE}" ]; then
    version=$(cat /etc/os-release | grep -oP '^VERSION_ID=["\"]?\K\w+')
    info "Overwrite identified version \"${version}\" with \"${_CODEBASE}\""

    if ! sudocmd "set a new release version": dnf -q -y config-manager --setopt=hyperion.releasever=${_CODEBASE} --save; then
      error "Failed to overwrite by the fedora release version."
    fi
  fi

  info "Install Hyperion..."
  info ""
  if ! sudocmd "install hyperion" dnf -y install hyperion; then
    error "Failed to install Hyperion. Please run 'dnf check-update' and try again."
  fi
}

# Attempts an uninstall on Fedora via dnf, if possible
function uninstall_dnf_package() {
  debug "Start uninstall via DNF package"

  info "Uninstall Hyperion..."
  info ""
  if ! sudocmd "uninstall hyperion" sh -c "dnf -y remove hyperion"; then
    error "Failed to uninstall Hyperion. Please try again."
  fi

  if ! sudocmd "remove the Hyperion-Project repository from your system" sh -c "rm -f /etc/yum.repos.d/hyperion.repo"; then
    error "Failed to remove the Hyperion Project Repository. Please check the log for any errors."
  fi
}

# Attempt to install on a Linux distribution
function install_hyperion() {

  if check_hyperion_installed ; then
    info "Hyperion $(installed_hyperion_version) is already installed. Use your OS's package manager to upgrade."
    exit 1
  fi

  if check_architecture "${_DISTRO}"; then
    case "$_DISTRO" in
      debian|ubuntu|raspbian)
        install_deb_package
        ;;
      fedora)
        install_dnf_package
        ;;
      *)
        error "Sorry, this installer doesn't support your Linux distribution."
    esac
  fi
}

function uninstall_hyperion() {
  if ! check_hyperion_installed; then
    error "Hyperion cannot be found and therefore cannot be removed."
  fi

  info "Found Hyperion $(installed_hyperion_version)"

  if prompt 'Are you sure you want to remove Hyperion? [Yes/No]'; then
    info 'No updates will be done. Exiting...'
    exit 99
  fi

  case  "${_DISTRO}" in
    debian|ubuntu|raspbian)
      uninstall_deb_package
      ;;
    fedora)
      uninstall_dnf_package
      ;;
    *)
      error "Sorry, this installer doesn't support your Linux distribution."
    esac
}

# Install packages using apt-get
apt_get_install_pkgs() {
  missing=
  for pkg in $*; do
    if ! dpkg -s "$pkg" 2>/dev/null | grep '^Status:.*installed' >/dev/null; then
      missing="$missing $pkg"
    fi
  done
  if [ "$missing" = "" ]; then
    debug "Packages '$*' already installed!"
  elif ! sudocmd "install required system dependencies" apt-get -qq install -y $missing; then
    error "\nInstalling apt packages failed.  Please run 'apt-get update' and try again."
  fi
}

# Get installed Hyperion version
function installed_hyperion_version() {
  hyperiond --version | grep -oP 'Version\s+:\s+\K[^\s]+'
}

# Check whether Hyperion is installed
function check_hyperion_installed() {
  has_cmd hyperiond
}

# Check whether the given command exists
function has_cmd() {
  command -v "$1" > /dev/null 2>&1
}

############################################
# Main
############################################

options=$(getopt -l "nightly,debian:,fedora:,ubuntu:,remove,verbose,help" -o "nd:f:u:rvh" -a -- "$@")

eval set -- "$options"
while true; do
  case $1 in
    -n|--nightly)
      _NIGHTLY="nightly."
      ;;
    -d|--debian)
      shift
      _DISTRO="debian"
      _CODEBASE=$1
      ;;
    -f|--fedora)
      shift
      _DISTRO="fedora"
      _CODEBASE=$1
      ;;
    -u|--ubunutu)
      shift
      _DISTRO="ubuntu"
      _CODEBASE=$1
      ;;
    -r|--remove)
      _REMOVE=true
      ;;
    -v|--verbose)
      _VERBOSE=true
      ;;
    -h|--help)
      printHelp
      exit 0
      ;;
    --)
      shift
      break;;
  esac
  shift
done

# Check, if executed under Linux
if [ "$(uname)" != "Linux" ] ; then
    error "Sorry, this installer does not support your operating system: $(uname).
See https://docs.hyperion-project.org/en/user/Installation.html"
fi

# Determine the used Linux distribution.
distro=$(get_distro)
if [ -n "${_DISTRO}" ]; then
  info "Overwrite identified distribution \"${distro}\" with \"${_DISTRO}\""
else
  _DISTRO=${distro}
  info "Identified distribution \"${_DISTRO}\""
fi

if $_REMOVE; then
  uninstall_hyperion
else
  install_hyperion
fi

info 'Done'
exit 0

