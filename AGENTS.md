# Agent Notes

- For TestFlight uploads, use `scripts/publish-testflight-xcodebuild.sh --version VERSION`. It archives and uploads through `xcodebuild -exportArchive` with `destination=upload`; do not use ASC CLI unless explicitly requested.
- The script works for any future marketing version and defaults the build number to a timestamp. Pass `--build-number BUILD_NUMBER` only when a specific build number is needed.
