#!/bin/zsh
# Simulator-only video helper. It sends an APNs-style notification after a short delay while
# CouponCock is not running; no app-side demo timer is included in production code.
set -euo pipefail

device_id="${1:-B5928ABE-9DD2-4A4B-BBA1-39CC3C5FE657}"
delay_seconds="${2:-1}"
script_dir="${0:A:h}"

sleep "$delay_seconds"
xcrun simctl push "$device_id" com.couponpilot.app "$script_dir/simulator-store-entry.apns"
