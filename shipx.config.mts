// CamFetti releases with shipx: bump MARKETING_VERSION in project.yml, tag, push, then archive
// and upload to App Store Connect. The Watch app ships inside the iOS archive. Apple TV and
// Vision Pro ship from the same target, with layered icons from scripts/gen-tv-vision-icons.py.
// Review submission stays a click in App Store Connect.
export default {
	steps: { homebrew: false, npm: false, watchCi: false },
	xcode: { scheme: "CamFetti", platforms: ["ios", "macos", "tvos", "visionos"], buildNumberOffset: 9 },
};
