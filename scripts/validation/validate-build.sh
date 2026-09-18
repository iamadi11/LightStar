#!/bin/bash
# LightStar Build Validation Script
# Run this on Mac with Xcode installed

set -e

echo "=== LightStar Build Validation ==="
echo ""

# Check environment
echo "1. Checking environment..."
echo "   Swift version:"
swift --version
echo ""
echo "   Xcode version:"
xcodebuild -version
echo ""

# Generate project
echo "2. Generating Xcode project..."
if ! command -v xcodegen &> /dev/null; then
    echo "   Installing xcodegen..."
    brew install xcodegen
fi
xcodegen generate
echo "   ✓ Project generated"
echo ""

# Run unit tests
echo "3. Running unit tests..."
cd LightStarCore
swift test
cd ..
echo "   ✓ Unit tests passed"
echo ""

# Build macOS
echo "4. Building macOS app..."
xcodebuild build \
    -project LightStar.xcodeproj \
    -scheme LightStar \
    -configuration Debug \
    -derivedDataPath /tmp/ls-validation \
    CODE_SIGNING_ALLOWED=NO \
    | xcpretty || xcodebuild build \
    -project LightStar.xcodeproj \
    -scheme LightStar \
    -configuration Debug \
    -derivedDataPath /tmp/ls-validation \
    CODE_SIGNING_ALLOWED=NO
echo "   ✓ macOS build succeeded"
echo ""

# Verify widget
echo "5. Verifying widget embedding..."
if [ -d "/tmp/ls-validation/Build/Products/Debug/LightStar.app/Contents/PlugIns/LightStarWidget.appex" ]; then
    echo "   ✓ Widget embedded correctly"
else
    echo "   ✗ Widget not found!"
    exit 1
fi
echo ""

# Build iOS
echo "6. Building iOS app..."
xcodebuild build \
    -project LightStar.xcodeproj \
    -scheme LightStariOS \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    | xcpretty || xcodebuild build \
    -project LightStar.xcodeproj \
    -scheme LightStariOS \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO
echo "   ✓ iOS build succeeded"
echo ""

echo "=== BUILD VALIDATION PASSED ==="
echo ""
echo "Summary:"
echo "  - Unit tests: PASS"
echo "  - macOS build: PASS"
echo "  - Widget embed: PASS"
echo "  - iOS build: PASS"
