#!/bin/bash -e -x

# Validates that iOS release and patch commands work as expected.
# This needs to be run locally on a machine with an iOS device attached.

rm -rf patchwing_temp
flutter create patchwing_temp --empty --platforms ios,macos
cd patchwing_temp
patchwing init -f
CI=1 patchwing release --platforms ios,macos
sed -i .orig 's/Hello World/Hello Patchwing/g' lib/main.dart
CI=1 patchwing patch --platforms ios,macos --release-version latest

patchwing preview --release-version 0.1.0+0.1.0 --platform ios > /dev/null &
patchwing preview --release-version 0.1.0+0.1.0 --platform macos > /dev/null &

echo "Once the patch is installed, kill the app and verify the 'Hello world! has been replaced by 'Hello patchwing'"