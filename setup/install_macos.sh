#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS. See setup/README.md for Windows and Linux."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is not installed."
  read -r -p "Install Homebrew from its official GitHub installer now? [y/N] " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Nothing was changed. See https://brew.sh and rerun this script."
    exit 1
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

echo "Updating Homebrew..."
brew update

echo "Installing command-line tools..."
brew install git python@3.12 terraform

echo "Installing desktop applications..."
for app in docker dbeaver-community cursor; do
  if ! brew list --cask "$app" >/dev/null 2>&1; then
    brew install --cask "$app"
  else
    echo "Already installed: $app"
  fi
done

cat <<'EOF'

Local tools are installed.

Next:
1. Open Docker Desktop and accept its first-run prompts.
2. Wait until Docker says the engine is running.
3. Close and reopen Terminal.
4. From the repository root run:

   python3 setup/verify_setup.py
   python3 setup/start_postgres.py

Next, continue at setup/MACOS_SETUP.md.
Astro CLI is installed in the Airflow episode, when it is first needed.
Snowflake is a browser account and is created in the Snowflake episode.
EOF
