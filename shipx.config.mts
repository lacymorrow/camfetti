// CamFetti releases with shipx: bump MARKETING_VERSION in project.yml, tag, push, then archive
// and upload to App Store Connect. The Watch app ships inside the iOS archive. Apple TV and
// Vision Pro join once they have had real use (add "tvos", "visionos").
// Review submission stays a click in App Store Connect.
export default {
	steps: { homebrew: false, npm: false, watchCi: false },
	xcode: { scheme: "CamFetti", platforms: ["ios", "macos"], buildNumberOffset: 9 },
};
