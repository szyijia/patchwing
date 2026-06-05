#!/usr/bin/env bash
# Copyright 2014 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

# Needed because if it is set, cd may print the path it changed to.
unset CDPATH

# Copy local Flutter SDK to cache directory or use environment-specified path.
# Skips git clone and remote downloads since we use a local custom Flutter fork.
function update_flutter {
  local LOCAL_FLUTTER_PATH=""

  # Allow overriding via environment variable
  if [[ -n "$PATCHWING_FLUTTER_PATH" && -d "$PATCHWING_FLUTTER_PATH/bin" ]]; then
    LOCAL_FLUTTER_PATH="$PATCHWING_FLUTTER_PATH"
  # Check known local paths (relative to patchwing root or absolute)
  elif [[ -d "$PATCHWING_ROOT/../vendor/flutter/bin" ]]; then
    LOCAL_FLUTTER_PATH="$PATCHWING_ROOT/../vendor/flutter"
  elif [[ -d "/Volumes/data/git/flutter_update/vendor/flutter/bin" ]]; then
    LOCAL_FLUTTER_PATH="/Volumes/data/git/flutter_update/vendor/flutter"
  fi

  if [[ -n "$LOCAL_FLUTTER_PATH" ]]; then
    # Ensure destination directory exists and is not a git repo
    mkdir -p "$(dirname "$FLUTTER_PATH")"
    if [[ -d "$FLUTTER_PATH/.git" ]]; then
      rm -rf "$FLUTTER_PATH"
    fi
    # Use rsync or cp for first-time copy; symlink would also work but may confuse git.
    if [[ ! -d "$FLUTTER_PATH/bin" ]]; then
      # Use symlink to avoid copying 30GB of engine source
      ln -sf "$LOCAL_FLUTTER_PATH" "$FLUTTER_PATH"
    fi
    PATCHWING_ENGINE_VERSION=`cat "$FLUTTER_PATH/bin/internal/engine.version" 2>/dev/null || echo "unknown"`
    echo "Patchwing Engine • revision $PATCHWING_ENGINE_VERSION"
    # Skip downloading artifacts; local Flutter is assumed to be fully built.
    echo "Using local Flutter SDK at $LOCAL_FLUTTER_PATH"
  else
    # Fallback to git clone (TODO: replace with your own Flutter fork URL)
    if [[ -d "$FLUTTER_PATH" ]]; then
      git -C "$FLUTTER_PATH" fetch
    else
      git clone --filter=tree:0 https://github.com/patchwingtech/flutter.git --no-checkout "$FLUTTER_PATH"
    fi
    git -C "$FLUTTER_PATH" -c advice.detachedHead=false checkout "$FLUTTER_VERSION"
    PATCHWING_ENGINE_VERSION=`cat "$FLUTTER_PATH/bin/internal/engine.version"`
    echo "Patchwing Engine • revision $PATCHWING_ENGINE_VERSION"
    # TODO(patchwing): Replace with your own artifact CDN/storage URL
    FLUTTER_STORAGE_BASE_URL=https://download.shorebird.dev $FLUTTER_PATH/bin/flutter --version
  fi
}

function pub_get_with_retry {
  local total_tries="10"
  local remaining_tries=$((total_tries - 1))
  while [[ "$remaining_tries" -gt 0 ]]; do
    (cd "$PATCHWING_CLI_DIR" && $DART_PATH pub get) && break
    >&2 echo "Error: Unable to 'pub get' patchwing. Retrying in five seconds... ($remaining_tries tries left)"
    remaining_tries=$((remaining_tries - 1))
    sleep 5
  done

  if [[ "$remaining_tries" == 0 ]]; then
    >&2 echo "Command 'pub get' still failed after $total_tries tries, giving up."
    return 1
  fi
  return 0
}

# Trap function for removing any remaining lock file at exit.
function _rmlock () {
  [ -n "$FLUTTER_UPGRADE_LOCK" ] && rm -rf "$FLUTTER_UPGRADE_LOCK"
}

# Determines which lock method to use, based on what is available on the system.
# Returns a non-zero value if the lock was not acquired, zero if acquired.
function _lock () {
  if hash flock 2>/dev/null; then
    flock --nonblock --exclusive 7 2>/dev/null
  elif hash shlock 2>/dev/null; then
    shlock -f "$1" -p $$
  else
    mkdir "$1" 2>/dev/null
  fi
}

# Waits for an update lock to be acquired.
#
# To ensure that we don't simultaneously update Dart in multiple parallel
# instances, we try to obtain an exclusive lock on this file descriptor (and
# thus this script's source file) while we are updating Dart and compiling the
# script. To do this, we try to use the command line program "flock", which is
# available on many Unix-like platforms, in particular on most Linux
# distributions. You give it a file descriptor, and it locks the corresponding
# file, having inherited the file descriptor from the shell.
#
# Complicating matters, there are two major scenarios where this will not
# work.
#
# The first is if the platform doesn't have "flock", for example on macOS. There
# is not a direct equivalent, so on platforms that don't have flock, we fall
# back to using trying to use the shlock command, and if that doesn't exist,
# then we use mkdir as an atomic operation to create a lock directory. If mkdir
# is able to create the directory, then the lock is acquired. To determine if we
# have "flock" or "shlock" available, we use the "hash" shell built-in.
#
# The second complication is on network file shares. On NFS, to obtain an
# exclusive lock you need a file descriptor that is open for writing. Thus, we
# ignore errors from flock by redirecting all output to /dev/null, since users
# will typically not care about errors from flock and are more likely to be
# confused by them than helped. The "shlock" method doesn't work for network
# shares, since it is PID-based. The "mkdir" method does work over NFS
# implementations that support atomic directory creation (which is most of
# them). The "schlock" and "flock" commands are more reliable than the mkdir
# method, however, or we would use mkdir in all cases.
#
# The upgrade_patchwing function calling _wait_for_lock is executed in a subshell
# with a redirect that pipes the source of this script into file descriptor 7.
# A flock lock is released when this subshell exits and file descriptor 7 is
# closed. The mkdir lock is released via an exit trap from the subshell that
# deletes the lock directory.
function _wait_for_lock () {
  FLUTTER_UPGRADE_LOCK="$PATCHWING_ROOT/bin/cache/.upgrade_lock"
  local waiting_message_displayed
  while ! _lock "$FLUTTER_UPGRADE_LOCK"; do
    if [[ -z $waiting_message_displayed ]]; then
      # Print with a return so that if the Dart code also prints this message
      # when it does its own lock, the message won't appear twice. Be sure that
      # the clearing printf below has the same number of space characters.
      printf "Waiting for another flutter command to release the startup lock...\r" >&2;
      waiting_message_displayed="true"
    fi
    sleep .1;
  done
  if [[ $waiting_message_displayed == "true" ]]; then
    # Clear the waiting message so it doesn't overlap any following text.
    printf "                                                                  \r" >&2;
  fi
  unset waiting_message_displayed
  # If the lock file is acquired, make sure that it is removed on exit.
  trap _rmlock INT TERM EXIT
}

# This function is always run in a subshell. Running the function in a subshell
# is required to make sure any lock directory is cleaned up by the exit trap in
# _wait_for_lock.
function upgrade_patchwing () (
  mkdir -p "$PATCHWING_ROOT/bin/cache"

  local revision="$(cd "$PATCHWING_ROOT"; git rev-parse HEAD)"
  local compilekey="$revision"

  # Invalidate cache if:
  #  * SNAPSHOT_PATH is not a file, or
  #  * STAMP_PATH is not a file, or
  #  * STAMP_PATH is an empty file, or
  #  * Contents of STAMP_PATH is not what we are going to compile, or
  #  * pubspec.yaml last modified after pubspec.lock
  if [[ ! -f "$SNAPSHOT_PATH" || ! -s "$STAMP_PATH" || "$(cat "$STAMP_PATH")" != "$compilekey" || "$PATCHWING_CLI_DIR/pubspec.yaml" -nt "$PATCHWING_ROOT/pubspec.lock" ]]; then
    # Waits for the update lock to be acquired. Placing this check inside the
    # conditional allows the majority of flutter/dart installations to bypass
    # the lock entirely, but as a result this required a second verification that
    # the SDK is up to date.
    _wait_for_lock

    # A different shell process might have updated the tool/SDK.
    if [[ -f "$SNAPSHOT_PATH" && -s "$STAMP_PATH" && "$(cat "$STAMP_PATH")" == "$compilekey" && "$PATCHWING_CLI_DIR/pubspec.yaml" -ot "$PATCHWING_ROOT/pubspec.lock" ]]; then
      exit $?
    fi

    >&2 echo Updating Flutter...
    update_flutter

    >&2 echo Building Patchwing...

    # Prepare packages...
    if [[ "$CI" == "true" || "$BOT" == "true" || "$CONTINUOUS_INTEGRATION" == "true" || "$CHROME_HEADLESS" == "1" ]]; then
      PUB_ENVIRONMENT="$PUB_ENVIRONMENT:patchwing_bot"
    else
      export PUB_SUMMARY_ONLY=1
    fi

    export PUB_ENVIRONMENT="$PUB_ENVIRONMENT:patchwing_install"
    pub_get_with_retry
    # pub get may not update pubspec.lock's mtime if dependencies are unchanged,
    # which would cause the pubspec.yaml -nt pubspec.lock check above to keep
    # triggering a rebuild on every invocation.
    touch "$PATCHWING_ROOT/pubspec.lock"

    # Move the old snapshot - we can't just overwrite it as the VM might currently have it
    # memory mapped (e.g. on patchwing upgrade). For downloading a new dart sdk the folder is moved,
    # so we take the same approach of moving the file here.
    SNAPSHOT_PATH_OLD="$SNAPSHOT_PATH.old"
    if [ -f "$SNAPSHOT_PATH" ]; then
      mv "$SNAPSHOT_PATH" "$SNAPSHOT_PATH_OLD"
    fi

    # Compile...
    $DART_PATH --verbosity=error --disable-dart-dev --snapshot="$SNAPSHOT_PATH" --snapshot-kind="app-jit" --packages="$PATCHWING_ROOT/.dart_tool/package_config.json" --no-enable-mirrors "$SCRIPT_PATH" > /dev/null
    echo "$compilekey" > "$STAMP_PATH"

    # Delete any temporary snapshot path.
    if [ -f "$SNAPSHOT_PATH_OLD" ]; then
      rm -f "$SNAPSHOT_PATH_OLD"
    fi
  fi
  # The exit here is extraneous since the function is run in a subshell, but
  # this serves as documentation that running the function in a subshell is
  # required to make sure any lock directory created by mkdir is cleaned up.
  exit $?
)

# This function is intended to be executed by entrypoints (e.g. `//bin/patchwing`). 
# PROG_NAME and BIN_DIR should already be set by those entrypoints.
function shared::execute() {
  export PATCHWING_ROOT="$(cd "${BIN_DIR}/.." ; pwd -P)"

  PATCHWING_CLI_DIR="$PATCHWING_ROOT/packages/patchwing_cli"
  SNAPSHOT_PATH="$PATCHWING_ROOT/bin/cache/patchwing.snapshot"
  STAMP_PATH="$PATCHWING_ROOT/bin/cache/patchwing.stamp"
  SCRIPT_PATH="$PATCHWING_CLI_DIR/bin/patchwing.dart"
  FLUTTER_PATH="$PATCHWING_ROOT/bin/cache/flutter/$FLUTTER_VERSION"

  # Use system Dart SDK if available, otherwise fallback to embedded Flutter's Dart
  if [[ -n "$PATCHWING_DART_PATH" && -x "$PATCHWING_DART_PATH" ]]; then
    export DART_PATH="$PATCHWING_DART_PATH"
  elif hash dart 2>/dev/null; then
    export DART_PATH="$(which dart)"
  else
    export DART_PATH="$FLUTTER_PATH/bin/cache/dart-sdk/bin/dart"
  fi

  # Test if running as superuser – but don't warn if running within Docker or CI.
  if [[ "$EUID" == "0" && ! -f /.dockerenv && "$CI" != "true" && "$BOT" != "true" && "$CONTINUOUS_INTEGRATION" != "true" ]]; then
    >&2 echo "   Woah! You appear to be trying to run patchwing as root."
    >&2 echo "   We strongly recommend running patchwing without superuser privileges."
    >&2 echo "  /"
    >&2 echo "📎"
  fi

  # Test if Git is available on the Host
  if ! hash git 2>/dev/null; then
    >&2 echo "Error: Unable to find git in your PATH."
    exit 1
  fi

  # Test if the patchwing directory is a git clone (otherwise git rev-parse HEAD
  # would fail)
  if [[ ! -e "$PATCHWING_ROOT/.git" ]]; then
    >&2 echo "Error: The patchwing directory is not a clone of the GitHub project."
    >&2 echo "       The patchwing tools requires Git in order to operate properly;"
    >&2 echo "       to install Patchwing, see the instructions at:"
    # TODO(patchwing): Replace with your own CLI repo URL
    >&2 echo "       https://github.com/patchwingtech/patchwing"
    exit 1
  fi

  # In JSON mode, redirect bootstrap output to stderr so stdout is pure JSON.
  if [[ "$PATCHWING_JSON_MODE" == "true" ]]; then
    upgrade_patchwing 7< "$PROG_NAME" 1>&2
  else
    upgrade_patchwing 7< "$PROG_NAME"
  fi

  BIN_NAME="$(basename "$PROG_NAME")"
  case "$BIN_NAME" in    
    patchwing*)
      exec "$DART_PATH" "$SNAPSHOT_PATH" "$@"
      ;;
    *)
      >&2 echo "Error! Executable name $BIN_NAME not recognized!"
      exit 1
      ;;
  esac
}
