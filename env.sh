#!/usr/bin/env bash
# Dev environment for payapp (Flutter + Android SDK + backend venv)
export JAVA_HOME=/home/vivek/Desktop/android-dev/jdk-17
export ANDROID_SDK_ROOT=/home/vivek/Desktop/android-dev/sdk
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_AVD_HOME=/home/vivek/Desktop/android-dev/avd
export ANDROID_USER_HOME=/home/vivek/Desktop/android-dev/user
export ANDROID_EMULATOR_HOME=/home/vivek/Desktop/android-dev/emulator-home
export GRADLE_USER_HOME=/home/vivek/Desktop/android-dev/gradle
export PUB_CACHE=/home/vivek/Desktop/flutter-sdk/pub-cache
export FLUTTER_ROOT=/home/vivek/Desktop/flutter-sdk/flutter
export PATH="$FLUTTER_ROOT/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
