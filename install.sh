#!/bin/bash
#
# Hyperion installation script.
#
# This script is meant for quick & easy install via:
#   'curl -sSL https://releases.hyperion-project.org/install | bash'
#   'curl -sSL https://releases.hyperion-project.org/install | bash -s -- --remove'
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
# Distribution
_DISTRO=""
# Alternate codebase
_CODEBASE=""
# Package repository URI
_BASE_REPO_URI="releases.hyperion-project.org"
# GitHub
_GITHUB_REPO="hyperion-project/hyperion.ng"
_GITHUB_API_URI="https://api.github.com/repos/${_GITHUB_REPO}"

_PYTONCMD=""

# Help print function
function printHelp {
	cat <<EOL
The script allows installing and removing Hyperion.

Options:
  -n, --nightly       Install the nightly build
  -u, --ubuntu        Use an alternate codebase for Ubuntu derivatives, e.g., use "jammy" for Pop!_OS 22.04 LTS or Mint 21.2 Victoria
  -d, --debian        Use an alternate codebase for Debian derivatives
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
	if [ -t 0 ]; then
		while true; do
			read -p "$1 " yn
			case "$(echo "$yn" | tr '[:upper:]' '[:lower:]')" in
			[yes]*) return 1 ;;
			[no]*) return 0 ;;
			*) echo "Please answer Yes or No." ;;
			esac
		done
	else
		echo "$1 "
		info "Non-interactive mode detected. Assuming default response (Yes)."
		return 1
	fi
}

function get_architecture() {
	# Determine the current architecture
	CURRENT_ARCHITECTURE=$(uname -m)

	# Test if multiarchitecture setup, i.e., user-space is 32-bit
	if [ "${CURRENT_ARCHITECTURE}" == "aarch64" ]; then
		CURRENT_ARCHITECTURE="arm64"
		USER_ARCHITECTURE=${CURRENT_ARCHITECTURE}
		IS_ARMHF=$(grep -m1 -c armhf /proc/$$/maps)
		if [ $IS_ARMHF -ne 0 ]; then
			USER_ARCHITECTURE="armhf"
		else
			IS_ARMEL=$(grep -m1 -c armel /proc/$$/maps)
			if [ $IS_ARMEL -ne 0 ]; then
				USER_ARCHITECTURE="armel"
			fi
		fi
		if [ "$CURRENT_ARCHITECTURE" != "$USER_ARCHITECTURE" ]; then
			CURRENT_ARCHITECTURE=$USER_ARCHITECTURE
		fi
	else
		# Change x86_xx to amdxx
		CURRENT_ARCHITECTURE=${CURRENT_ARCHITECTURE//x86_/amd}
		# Remove 'l' from armv6l, armv7l
		CURRENT_ARCHITECTURE=${CURRENT_ARCHITECTURE//l/}
	fi
	echo "${CURRENT_ARCHITECTURE}"
}

function get_github_artifacts_architecture() {
	# translate the architecture in the one used for artifacts build via GitHub
	architecture=$(get_architecture)
	case "$architecture" in
	armhf)
		architecture='armv7'
		;;
	armel)
		architecture='armv6'
		;;
	esac
	echo "${architecture}"
}

check_architecture() {
	# Checks if the current architecture is supported
	distro="$1"
	shift

	valid_architectures=''
	case "$distro" in
	debian | ubuntu | raspbian | libreelec)
		valid_architectures='armv6, armv7, armhf, armel, arm64, amd64'
		;;
	fedora)
		valid_architectures='amd64'
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
	if command -v lsb_release >/dev/null 2>&1; then
	    distro=$(lsb_release -si | awk '{print $1}')
	else
	    distro=$(cat /etc/os-release | grep -oP '^ID=["\"]?\K\w+')
	fi

	echo "${distro}" | tr '[:upper:]' '[:lower:]'
}

# Adds a 'sudo' prefix if sudo is available to execute the given command
# If not, the given command is run as is
# When requesting root permission, always show the command and never re-use cached credentials.
function sudocmd() {
	reason="$1"
	shift

	if command -v sudo >/dev/null; then
		# Check if sudo is required for the command
		sudoRequired=$(sudo -l "$@" 2>/dev/null)
		if [ $? -eq 0 ]; then
			debug
			debug "About to use 'sudo' to run the following command as root:"
			debug "    $@"
			debug "in order to $reason."
			debug
			sudo "$@"
		else
			debug
			debug "Running the following command:"
			debug "    $@"
			debug "in order to $reason."
			debug
			"$@"
		fi
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

	DEB822="X-Repolib Name: Hyperion
Enabled: yes
Types: deb
URIs: https://${_NIGHTLY}apt.${_BASE_REPO_URI}
Components: main
Suites: ${suites}
Signed-By: /etc/apt/keyrings/hyperion.pub.gpg"

	if ! sudocmd "add Hyperion Project repository to the system" echo "$DEB822" | sudo tee "/etc/apt/sources.list.d/hyperion.sources" >/dev/null; then
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

	if ! sudocmd "remove the Hyperion-Project APT source from your system" sh -c "rm -f /usr/share/keyrings/hyperion.pub.gpg /etc/apt/sources.list.d/hyperion*.sources /etc/apt/sources.list.d/hyperion*.list"; then
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

# Attempts an install of the latest github release
function install_github_package() {
	targetDirectory="$1"
	homeDirectory="$2"
	shift

	if [ -n "${_NIGHTLY}" ]; then
		error "GibHub release installation does not support nighly releases."
	fi

	info "Start GitHub release installation."
	debug "Determine latest release..."

	# Determine latest release
	releaseResponse=$(curl -s "${_GITHUB_API_URI}/releases/latest")
	if [ -z "${releaseResponse}" ]; then
		error "Failed to retrieve the latest GibHub release."
	fi

	latestRelease=$(echo "$releaseResponse" | tr '\r\n' ' ' | ${_PYTONCMD} -c """
import json,sys
data = json.load(sys.stdin)
latest_tag = data.get('tag_name', "")
print(latest_tag)
""" 2>/dev/null)

if [ -z "${latestRelease}" ]; then
	error "Latest GibHub release not found."
fi
info "Latest GibHub release identified: ${latestRelease}"

architecture=$(get_github_artifacts_architecture)

suffix='tar.gz'
download_url=$(echo "$releaseResponse" | tr '\r\n' ' ' | ${_PYTONCMD} -c """
import json
import sys
import fnmatch
data = json.load(sys.stdin)
architecture = '$architecture'
suffix = '$suffix'

for asset in data['assets']:
    if fnmatch.fnmatch(asset['name'], '*' + architecture + '*.' + suffix):
        print(asset['browser_download_url'])        
        break
""" 2>/dev/null)

	debug "Download URL: ${download_url}"
	if [ -z "$download_url" ]; then
		error "Download URL was not resolved."
	fi

	curl -# -L --get ${download_url} | tar --strip-components=1 -C ${targetDirectory} share/hyperion -xz ||
		error "Failed to download and extract the release."

	# Set the execute bit on files if curl was successful
	chmod +x -R ${targetDirectory}/hyperion/bin

	create_hyperion_service ${targetDirectory} ${homeDirectory}

	if check_rpi; then
		info "Configure Raspberry Pi specifics."
		install_SPI
	fi
}

# Attempts an uninstall
function uninstall_github_package() {
	directory="$1"
	shift
	debug "Start uninstall non-packaged installation"

	remove_hyperion_service ${directory}

	info "Uninstall Hyperion..."
	if [ -z "$directory" ]; then
		if ! sudocmd "remove the Hyperion binaries" rm -rf /usr/bin/hyperion*; then
			error "Failed to remove Hyperion binaries."
		fi
		if ! sudocmd "remove the Hyperion shared files" rm -rf /usr/share/hyperion; then
			error "Failed to remove Hyperion shared files."
		fi
	else
		if ! sudocmd "remove the Hyperion installation directory" rm -rf ${directory}/hyperion; then
			error "Failed to remove the Hyperion installation directory."
		fi
	fi

	info "Hyperion has been removed."
}

# Attempt to install on a Linux distribution
function install_hyperion() {

	if check_architecture "${_DISTRO}"; then
		case "$_DISTRO" in
		debian | ubuntu | raspbian)
			check_hyperion_installed
			check_curl_installed
			install_deb_package
			;;
		fedora)
			check_hyperion_installed
			install_dnf_package
			;;
		libreelec)
			basepath="/storage"
			homeDirectory="${basepath}"
			check_hyperion_installed "${basepath}/hyperion/bin/"
			check_curl_installed
			check_python_installed
			install_github_package "${basepath}" "${homeDirectory}"
			;;
		*)
			error "Sorry, this installer does not support your Linux distribution."
			;;
		esac
	fi
}

function uninstall_hyperion() {

	case "${_DISTRO}" in
	debian | ubuntu | raspbian)
		check_hyperion_removable
		uninstall_deb_package
		;;
	fedora)
		check_hyperion_removable
		uninstall_dnf_package
		;;
	libreelec)
		basepath="/storage"
		check_hyperion_removable "${basepath}/hyperion/bin/"
		uninstall_github_package "${basepath}"
		;;
	*)
		error "Sorry, this installer does not support your Linux distribution."
		;;
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
		error "Installing apt packages failed.  Please run 'apt-get update' and try again."
	fi
}

# Get installed Hyperion version
function installed_hyperion_version() {
	path="$1"
	shift
	echo $(${path}hyperiond --service --version | awk -F'[:()]' '/Version/ {print $2}')
}

# Check whether Hyperion is installed
function check_hyperion_installed() {
	path="$1"
	shift
	if has_cmd hyperiond || [ -d "${path}" ]; then
		info "Hyperion $(installed_hyperion_version ${path}) is already installed."
		exit 1
	fi
}

# Check whether Hyperion is installed
function check_hyperion_removable() {
	path="$1"
	shift
	if has_cmd hyperiond || [ -d "${path}" ]; then
		info "Found Hyperion $(installed_hyperion_version ${path})"
		if prompt 'Are you sure you want to remove Hyperion? [Yes/No]'; then
			info 'No updates will be done. Exiting...'
			exit 99
		fi
	else
		error "Hyperion cannot be found and therefore cannot be removed."
	fi
}

# Check whether curl is installed
function check_curl_installed() {
	if ! has_cmd "curl"; then
		error 'curl is required to download a release'
	fi
}

# Check whether python is installed
function check_python_installed() {
	if has_cmd "python3"; then
		_PYTONCMD="python3"
	else
		if has_cmd "python"; then
			_PYTONCMD="python"
		else
			error 'python3 or python2 is required to download a release'
		fi
	fi
}

# Check whether the given command exists
function has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# Check if running on a Raspberry Pi
function check_rpi() {
	if [[ -f "/proc/device-tree/compatible" ]]; then
		model=$(cat "/proc/device-tree/compatible")
		if $(echo ${model} | grep -qi 'bcm'); then
			debug "Identified Raspberry Pi model: ${model}"
			return 0
		fi
	fi
	return 1
}

# Create hyperion service
function create_hyperion_service() {

	path="$1"
	homeDirectory="$2"
	shift

	if [ -z ${homeDirectory} ]; then
		envHome=""
		homeDirectory=${path}
	else
		envHome="Environment=HOME=${homeDirectory}"
	fi

	debug "Create hyperion systemd service."
	debug "App  directory: ${path}"
	debug "HOME directory: ${homeDirectory}"

	service_unit="[Unit]
Description=Hyperion ambient light systemd service for user %i
Documentation=https://docs.hyperion-project.org
Requisite=network.target
Wants=network-online.target
After=network-online.target
After=systemd-resolved.service

[Service]
${envHome}
Environment=DISPLAY=:0.0
ExecStart=${path}/hyperion/bin/hyperiond --userdata ${homeDirectory}/.hyperion --service
WorkingDirectory=${path}/hyperion/bin
User=%i
TimeoutStopSec=5
KillMode=mixed
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target"

	echo "$service_unit" >${path}/.config/system.d/hyperion@.service

	username=${SUDO_USER:-$(whoami)}
	new_service="hyperion@${username}.service"

	debug "Enable Hyperion service: ${new_service}"
	systemctl enable --quiet ${new_service} >/dev/null 2>&1

	info "Start Hyperion service ${new_service} for user ${username}"
	systemctl start hyperion"@${username}"

	return 0
}

# Remove hyperion service
function remove_hyperion_service() {

	path="$1"
	shift

	CURRENT_SERVICE=$(systemctl --type service | grep -o 'hyperion.*\.service' || true)

	if [[ ! -z ${CURRENT_SERVICE} ]]; then
		info "Stopping current service: ${CURRENT_SERVICE}"

		if ! sudocmd "stop the Hyperion systemd service" systemctl --quiet stop ${CURRENT_SERVICE} --now; then
			echo "Failed to stop service: ${CURRENT_SERVICE}. Stop Hyperion manually."
		fi

		if ! sudocmd "disable the Hyperion systemd service" systemctl --quiet disable ${CURRENT_SERVICE} --now; then
			error "Failed to disable service: ${CURRENT_SERVICE}."
		fi
	fi

	info "Removing Hyperion systemd service..."

	if ! sudocmd "remove the Hyperion systemd service file" rm -rf ${path}/.config/system.d/hyperion@.service; then
		error "Failed to remove Hyperion systemd service file."
	fi

	if ! sudocmd "reload systemd daemon" systemctl --quiet daemon-reload; then
		error "Failed to reload systemd daemon."
	fi

	if ! sudocmd "reset systemd daemon" systemctl --quiet reset-failed; then
		error "Failed to reset systemd daemon."
	fi

	return 0
}

function install_SPI() {
	SPIOK=$(grep '^\dtparam=spi=on' /flash/config.txt | wc -l)
	if [ $SPIOK -ne 1 ]; then
		mount -o remount,rw /flash
		info 'SPI is currently not active, enabling "dtparam=spi=on" in /flash/config.txt'
		sed -i '$a dtparam=spi=on' /flash/config.txt
		mount -o remount,ro /flash
		info "Please reboot system to activate SPI configuration."
	fi
}

# Main

options=$(getopt -l "nightly,debian:,ubuntu:,remove,verbose,help" -o "nd:u:rvh" -n "install.sh" -a -- "$@")

if [ $? -ne 0 ]; then
	echo "Error: Invalid option provided."
	printHelp
	exit 1
fi

eval set -- "$options"
while true; do
	case "${1}" in
	-n | --nightly)
		_NIGHTLY="nightly."
		;;
	-d | --debian)
		_DISTRO="debian"
		shift
		_CODEBASE=$1
		;;
	-u | --ubuntu)
		_DISTRO="ubuntu"
		shift
		_CODEBASE=$1
		;;
	-r | --remove)
		_REMOVE=true
		;;
	-v | --verbose)
		_VERBOSE=true
		;;
	-h | --help)
		printHelp
		exit 0
		;;
	--)
		shift
		break
		;;
	esac
	shift
done

# Check for unrecognized options
if [ "$#" -gt 0 ]; then
	echo "Error: Unrecognized parameter: $1"
	printHelp
	exit 1
fi

# Check, if executed under Linux
if [ "$(uname)" != "Linux" ]; then
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
