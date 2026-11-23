#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test -d dist/VoiceController.app
test -d dist/ScreenClient.app
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto dist/VoiceController.app "$stage/VoiceController.app"
ditto dist/ScreenClient.app "$stage/ScreenClient.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "语音三屏集控" -srcfolder "$stage" -format UDZO -ov dist/VoiceScreenControl.dmg
