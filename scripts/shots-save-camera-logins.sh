#!/bin/bash
# Saves the logins of the cameras used for website and App Store screenshots to this Mac's
# Keychain, so scripts/shots-seed.py can add them to simulators without anyone typing or
# printing a password. Run it yourself in Terminal; it asks for each password without echoing it.
# Remove later with: security delete-generic-password -s camfetti-shots -a <name>
set -euo pipefail

save() {
	local name="$1" address="$2" user
	read -r -p "User name for $name ($address) [admin]: " user
	user="${user:-admin}"
	read -r -s -p "Password for $name, Enter to skip: " pass
	echo
	[ -z "$pass" ] && return
	security add-generic-password -U -s camfetti-shots -a "$name" -l "CamFetti screenshots: $name" \
		-j "$address|$user" -w "$pass"
	echo "  saved"
}

save "Front of House" "${1:?usage: $0 <front-ip> <back-ip> <driveway-ip>}"
save "Back of House" "${2:?}"
save "Driveway" "${3:?}"
