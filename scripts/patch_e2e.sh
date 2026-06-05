#!/bin/bash -ex

# This script tests the patching functionality of Patchwing.
# It creates a new empty, flutter project, initializes Patchwing,
# creates a new release, patches the release, and then ensures
# that the patch was applied correctly.
#
# Pre-requisites:
# - Flutter must be installed.
# - Android SDK must be installed.
# - ADB must be installed and be part of PATH.
# - Android emulator must be running.
# - Patchwing must be installed.
#
# Usage: ./patch_e2e.sh <flutter-version>

FLUTTER_VERSION=$1

# Intentionally including a space in the path.
TEMP_DIR=$(mktemp -d -t 'patchwing workspace-XXXXX')
cd "$TEMP_DIR"

# Create a new empty flutter project
flutter create e2e_test --org com.example.e2e_test --empty --platforms android
cd e2e_test

# Replace the contents of "lib/main.dart" with a single print statement.
echo "void main() { print('hello world'); }" >lib/main.dart

# Initialize Patchwing
patchwing init --force -v

# Run Flutter & Patchwing doctor to ensure that the project is set up correctly.
flutter doctor --verbose
patchwing doctor --verbose

# Point to the development environment
echo "base_url: https://api-dev.patchwing.net" >>patchwing.yaml

# Extract the app_id from the "patchwing.yaml"
APP_ID=$(cat patchwing.yaml | grep 'app_id:' | awk '{print $2}')

# Create Debug Keystore
# Android Studio creates this keystore by default, but we need to create it manually for CI.
# See https://github.com/google/bundletool/blob/69c3e0947bab350fbe7cbd9af03a77b0204d6dc8/src/main/java/com/android/tools/build/bundletool/commands/BuildApksCommand.java
keytool -genkey -v -keystore ~/.android/debug.keystore -keyalg RSA \
    -keysize 2048 -validity 10000 -alias AndroidDebugKey -storepass android -keypass android \
    -dname "CN=Android Debug,O=Android,C=US"

# Create a new release on Android
patchwing release android --flutter-version=$FLUTTER_VERSION --split-debug-info=./build/symbols -v

# Run the app on Android and ensure that the print statement is printed.
while IFS= read line; do
    if [[ "$line" == *"I flutter : hello world"* ]]; then
        adb kill-server
        echo "✅ 'hello world' was printed"
        break
    fi
done < <(patchwing preview --release-version 0.1.0+1 --app-id $APP_ID --platform android -v)

# Replace lib/main.dart "hello world" to "hello patchwing"
sed -i 's/hello world/hello patchwing/g' lib/main.dart

echo "lib/main.dart is now:"
cat lib/main.dart

# Create a patch
patchwing patch android --release-version 0.1.0+1 --split-debug-info=./build/symbols -v

# Run the app on Android and ensure that the original print statement is printed.
while IFS= read line; do
    if [[ "$line" == *"Patch 1 successfully"* ]]; then
        # Kill the app so we can boot the patch
        adb shell am force-stop com.example.e2e_test.e2e_test
        echo "✅ Patch 1 successfully installed"
        break
    fi
done < <(patchwing preview --release-version 0.1.0+1 --app-id $APP_ID --platform android -v)

# Re-run the app, *not* using patchwing preview, as that installs the base release.
adb shell monkey -p com.example.e2e_test.e2e_test -c android.intent.category.LAUNCHER 1

# Re-run the app on Android and ensure that the new print statement is printed,
# tailing adb logs and printing the last 10 seconds of logs in case the
# "hello patchwing" statement was printed before entering the loop.
while IFS= read line; do
    if [[ "$line" == *"I flutter : hello patchwing"* ]]; then
        adb kill-server
        echo "✅ 'hello patchwing' was printed"
        break
    fi
done < <(adb logcat -T '10.0')

echo "✅ All tests passed!"
exit 0
