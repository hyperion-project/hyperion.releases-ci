#!/bin/sh -e
#
# Hyperion installation script.
#
# This script is meant for quick & easy install via:
#   'curl -sSL https://releases.hyperion-project.org/install | sh'
# or:
#   'wget -qO- https://releases.hyperion-project.org/install | sh'
#
# This is based on get-stack.sh which is Copyright (c) 2015-2023, Stack contributors.
# https://github.com/commercialhaskell/stack/blob/master/etc/scripts/get-stack.sh
#

# print a message to stderr and exit with error code
die() {
  echo "$@" >&2
  exit 1
}

# determines the CPU's instruction set architecture (ISA)
get_isa() {
  if uname -m | grep -Eq 'armv[78]l?' ; then
    echo armhf
  elif uname -m | grep -q aarch64 ; then
    echo arm64
  elif uname -m | grep -q arm64 ; then
    echo arm64
  elif uname -m | grep -q x86 ; then
    echo amd64
  else
    die "$(uname -m) is not a supported instruction set"
  fi
}

# exits with code 0 if arm ISA is detected as described above
is_arm() {
  test "$(get_isa)" = armhf
}

# exits with code 0 if aarch64 ISA is detected as described above
is_aarch64() {
  test "$(get_isa)" = arm64
}

# determines 64- or 32-bit architecture
# if getconf is available, it will return the arch of the OS, as desired
# if not, it will use uname to get the arch of the CPU, though the installed
# OS could be 32-bits on a 64-bit CPU
get_arch() {
  if has_getconf ; then
    if getconf LONG_BIT | grep -q 64 ; then
      echo 64
    else
      echo 32
    fi
  else
    case "$(uname -m)" in
      *64)
        echo 64
        ;;
      *)
        echo 32
        ;;
    esac
  fi
}

# exits with code 0 if a x86_64-bit architecture is detected as described above
is_x86_64() {
  test "$(get_arch)" = 64 -a "$(get_isa)" = "amd64"
}

# Adds a 'sudo' prefix if sudo is available to execute the given command
# If not, the given command is run as is
# When requesting root permission, always show the command and never re-use cached credentials.
sudocmd() {
  reason="$1"; shift
  if command -v sudo >/dev/null; then
    echo
    echo "About to use 'sudo' to run the following command as root:"
    echo "    $@"
    echo "in order to $reason."
    echo
    sudo -k "$@" # -k: Disable cached credentials (force prompt for password).
  else
    "$@"
  fi
}

# Attempts an install on Debian/Ubuntu via apt, if possible
do_debian_ubuntu_install() {
  if is_arm || is_x86_64 || is_aarch64 ; then
    info "Installing dependencies..."
    info ""
    apt_get_install_pkgs gpg apt-transport-https

    info "Integrate Repository..."
    info ""
    DOWNLOAD_GPG_KEY="curl --silent --show-error --location 'https://releases.hyperion-project.org/hyperion.pub.key' | gpg --dearmor -o /etc/apt/keyrings/hyperion.pub.gpg"
    if ! sudocmd "download public gpg key from Hyperion Project repository" sh -c '$DOWNLOAD_GPG_KEY'; then
      die "\nFailed to download the public key from the Hyperion Project Repository. Please run 'apt-get update' and try again."
    fi

    ARCHITECTURE="$(get_isa)"
    DEB822="Name: Hyperion\nEnabled: yes\nTypes: deb\nURIs: https://apt.releases.hyperion-project.org\nComponents: main\nArchitectures: $ARCHITECTURE\nSigned-By: /etc/apt/keyrings/hyperion.pub.gpg"
    if ! sudocmd "add Hyperion Project repository to the system" printf '$DEB822' > /etc/apt/sources.list.d/hyperion.sources; then
      die "\nFailed to add the Hyperion Project Repository. Please run 'apt-get update' and try again."
    fi

    info "Install Hyperion..."
    info ""
    if ! sudocmd "install hyperion" sh -c 'apt-get update && apt-get -y install hyperion'; then
      die "\nFailed to install Hyperion. Please run 'apt-get update' and try again."
    fi
  else
    die "Sorry, only arm, x86_64 and aarch64 Linux binaries are currently available."
  fi
}

# Attempts an install on Fedora via dnf, if possible
do_fedora_install() {
  if is_x86_64 ; then
    info "Installing dependencies..."
    info ""
    if ! sudocmd "install required system dependencies" dnf -q install -y dnf-plugins-core; then
      die "\nFailed to install required system dependencies. Please run 'dnf check-update' and try again."
    fi

    info "Integrate Hyperion Project Repository..."
    info ""
    if ! sudocmd "add Hyperion Project repository to the system:" dnf -q -y config-manager --add-repo https://dnf.releases.hyperion-project.org/fedora/hyperion.repo; then
      die "\nFailed to add the Hyperion Project Repository. Please run 'dnf check-update' and try again."
    fi

    info "Install Hyperion..."
    info ""
    if ! sudocmd "install hyperion" dnf -y install hyperion; then
      die "\nFailed to install Hyperion. Please run 'dnf check-update' and try again."
    fi
  else
    die "Sorry, only 64-bit (x86_64) Linux binaries are currently available."
  fi
}

# Attempts to determine the running Linux distribution.
# Prints "DISTRO" (distribution name).
distro_info() {
  parse_lsb() {
    lsb_release -a 2> /dev/null | perl -ne "$1"
  }

  try_lsb() {
    if has_lsb_release ; then
      TL_DIST="$(parse_lsb 'if(/Distributor ID:\s+([^ ]+)/) { print "\L$1"; }')"
      echo "$TL_DIST"
    else
      return 1
    fi
  }

  try_release() {
    parse_release() {
      perl -ne "$1" /etc/*release 2>/dev/null
    }

    parse_release_id() {
      parse_release 'if(/^(DISTRIB_)?ID\s*=\s*"?([^"]+)/) { print "\L$2"; exit 0; }'
    }

    TR_RELEASE="$(parse_release_id)"

    if [ ";" = "$TR_RELEASE" ] ; then
      return 1
    else
      echo "$TR_RELEASE"
    fi
  }

  try_lsb || try_release
}

# Attempt to install on a Linux distribution
do_install() {
  if [ "$(uname)" != "Linux" ] ; then
    die "Sorry, this installer does not support your operating system: $(uname).
See https://docs.hyperion-project.org/en/user/Installation.html"
  fi

  IFS=";" read -r DISTRO <<GETDISTRO
$(distro_info)
GETDISTRO

  if [ -n "$DISTRO" ] ; then
    info "Detected Linux distribution: $DISTRO"
    info ""
  fi

  case "$DISTRO" in
    debian|ubuntu|raspbian)
      do_debian_ubuntu_install
      ;;
    fedora)
      do_fedora_install
      ;;
    *)
      die "Sorry, this installer doesn't support your Linux distribution."
  esac
}

# Install packages using apt-get
apt_get_install_pkgs() {
  missing=
  for pkg in $*; do
    if ! dpkg -s $pkg 2>/dev/null |grep '^Status:.*installed' >/dev/null; then
      missing="$missing $pkg"
    fi
  done
  if [ "$missing" = "" ]; then
    info "Already installed!"
  elif ! sudocmd "install required system dependencies" apt-get -qq install -y $missing; then
    die "\nInstalling apt packages failed.  Please run 'apt-get update' and try again."
  fi
}

# Get installed Hyperion version
installed_hyperion_version() {
  hyperiond --version | grep -o 'Version \([[:digit:]]\|\.\)\+' | tr A-Z a-z
}

# Check whether 'hyperiond' command exists
has_hyperion() {
    has_cmd hyperiond
}

# Check whether 'lsb_release' command exists
has_lsb_release() {
  has_cmd lsb_release
}

# Check whether 'sudo' command exists
has_sudo() {
  has_cmd sudo
}

# Check whether 'getconf' command exists
has_getconf() {
  has_cmd getconf
}

# Check whether 'apt-get' command exists
has_apt_get() {
  has_cmd apt-get
}

# Check whether 'dnf' command exists
has_dnf() {
  has_cmd dnf
}

# Check whether the given command exists
has_cmd() {
  command -v "$1" > /dev/null 2>&1
}

# Check whether Hyperion is already installed, and print an error if it is.
check_hyperion_installed() {
  if has_hyperion ; then
    die "Hyperion $(installed_hyperion_version) already appears to be installed. Use your OS's package manager to upgrade."
  fi
}

check_hyperion_installed
do_install