export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Release: the speech models run several times faster optimized.
run: build
	-osascript -e 'tell application id "dev.alexis.Hypervoice" to quit' 2>/dev/null
	while lsappinfo find bundleid=dev.alexis.Hypervoice | grep -q ASN; do sleep 0.2; done
	open -n build/Build/Products/Release/Hypervoice.app

build:
	xcodegen generate -q
	xcodebuild -project Hypervoice.xcodeproj -scheme Hypervoice -configuration Release -derivedDataPath build -quiet build

.PHONY: run build
