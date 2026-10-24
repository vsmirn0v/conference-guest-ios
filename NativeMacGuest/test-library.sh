#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(dirname -- "$source_dir")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-library.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
core_dir="${NATIVE_GUEST_CORE_BUILD_DIR:-$repo_dir/.build/native-guest/library-core}"
swift build --package-path "$repo_dir/ConferenceCore" --scratch-path "$core_dir" --product ConferenceCore
core_products="$(swift build --package-path "$repo_dir/ConferenceCore" --scratch-path "$core_dir" --show-bin-path)"
sources=("$repo_dir/Shared/Localization.swift")
for name in RoomHistoryStore RoomSyncCoordinator CloudRoomTransport AppleCalendarReader CalendarMeetingStore CalendarInvitationContext CalendarReminderRepository CalendarReminderCoordinator CalendarReminderNotifications ReminderProfileCloud MeetingContinuationCloud MeetingContinuationCoordinator MeetingSetupCoordinator HomeMeetingCard; do
    sources+=("$repo_dir/RockNRoll/$name.swift")
done
for name in VendorEndpointResolver AdditionalRootTrust GuestSiteLinkAdapter; do
    sources+=("$repo_dir/RockNRoll/VendorIntegration/$name.swift")
done
swiftc -swift-version 5 -parse-as-library -I "$core_products" -L "$core_products" -lConferenceCore \
    "${sources[@]}" "$source_dir"/Data/*.swift "$source_dir/Tests/NativeDesktopLibraryTests.swift" \
    -o "$build_dir/native-library-tests"
cp -R "$core_products/ConferenceCore_ConferenceCore.bundle" "$build_dir/"
"$build_dir/native-library-tests"
