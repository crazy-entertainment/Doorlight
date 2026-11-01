/// The complete visual palettes offered by Doorlight.
///
/// This value lives outside the Flutter theme layer so settings persistence
/// remains a platform-agnostic concern.
enum AppearancePreset {
  // Keep the stored key so existing Calm selections become Disaccord.
  disaccord('calm'),
  cozy('cozy'),
  midnight('midnight');

  const AppearancePreset(this.storageValue);

  final String storageValue;

  static AppearancePreset? tryParse(Object? value) {
    if (value is! String) return null;
    for (final preset in values) {
      if (preset.storageValue == value) return preset;
    }
    return null;
  }
}
