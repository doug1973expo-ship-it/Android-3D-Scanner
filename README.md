# Pocket 3D Scanner

Standalone Android 3D scanning using ARCore depth data, with feature-point fallback. Samples are fused into a 6 mm voxel surface and exported as a binary STL in millimetres.

## Using the app

1. Put a small, non-shiny, textured object in bright, even light.
2. Tap **Start scan** and circle it slowly while keeping it in view.
3. Capture the front, sides and top, then tap **Stop scan**.
4. Tap **Export STL** and save or share the file.

This first version captures all visible geometry, so use your slicer's cut tool to remove the table or unwanted surroundings. Every push builds an APK and publishes the raw app-debug.apk under GitHub **Releases**.
