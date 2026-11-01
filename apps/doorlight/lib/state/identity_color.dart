import 'dart:math' as math;

enum IdentityColor {
  amber('amber', 'Amber', 0xFFF2B775),
  coral('coral', 'Coral', 0xFFF08A6C),
  rose('rose', 'Rose', 0xFFD97A9A),
  violet('violet', 'Violet', 0xFFA98BD4),
  sky('sky', 'Sky', 0xFF7FAFD8),
  teal('teal', 'Teal', 0xFF67BEB6),
  sage('sage', 'Sage', 0xFF8FBE83),
  lime('lime', 'Lime', 0xFFB5C96A),
  red('red', 'Red', 0xFFE86B69),
  orange('orange', 'Orange', 0xFFEF9D5D),
  yellow('yellow', 'Yellow', 0xFFE6CA63),
  green('green', 'Green', 0xFF6ACB7A),
  emerald('emerald', 'Emerald', 0xFF49AF84),
  mint('mint', 'Mint', 0xFF73D1B1),
  cyan('cyan', 'Cyan', 0xFF58C7D7),
  ice('ice', 'Ice', 0xFF9DCFE7),
  azure('azure', 'Azure', 0xFF559CE0),
  blue('blue', 'Blue', 0xFF6386E5),
  cobalt('cobalt', 'Cobalt', 0xFF5570C5),
  navy('navy', 'Navy', 0xFF526994),
  indigo('indigo', 'Indigo', 0xFF8277CD),
  magenta('magenta', 'Magenta', 0xFFC975BD),
  slate('slate', 'Slate', 0xFF98A4B7),
  ivory('ivory', 'Ivory', 0xFFE3DDC9);

  const IdentityColor(this.storageValue, this.label, this.argb);

  final String storageValue;
  final String label;
  final int argb;

  /// Hue order is presentation only; stored and wire keys remain stable.
  static const palette = <IdentityColor>[
    red,
    coral,
    orange,
    amber,
    yellow,
    lime,
    sage,
    green,
    emerald,
    mint,
    teal,
    cyan,
    ice,
    sky,
    azure,
    blue,
    cobalt,
    navy,
    indigo,
    violet,
    magenta,
    rose,
    slate,
    ivory,
  ];

  static IdentityColor? tryParse(Object? value) {
    if (value is! String) return null;
    for (final color in values) {
      if (color.storageValue == value) return color;
    }
    return null;
  }

  /// The default belongs to the identity; friends only influence suggestions.
  static IdentityColor automaticFor(String identityId) {
    final identity = identityId.trim().toLowerCase();
    var hash = 0x811c9dc5;
    for (final unit in identity.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return palette[hash % palette.length];
  }

  /// Choose distinct options first, then present them in the same hue order
  /// as the full palette. Occupied colors remain available in the full picker.
  static List<IdentityColor> recommended(
    Iterable<IdentityColor> friends, {
    required IdentityColor current,
  }) {
    final used = friends.toSet();
    final selected = <IdentityColor>[current];
    while (selected.length < 6) {
      IdentityColor? best;
      var bestScore = -1.0;
      for (final candidate in palette) {
        if (selected.contains(candidate) ||
            candidate == slate ||
            candidate == ivory) {
          continue;
        }
        final diversity = _nearest(candidate, selected);
        final score = used.isEmpty
            ? diversity
            : _nearest(candidate, used) + diversity * 0.35;
        if (score > bestScore) {
          best = candidate;
          bestScore = score;
        }
      }
      selected.add(best!);
    }
    selected.sort((a, b) => palette.indexOf(a).compareTo(palette.indexOf(b)));
    return List.unmodifiable(selected);
  }

  /// CIE Lab distance distinguishes lightness and shade as well as hue.
  double distanceTo(IdentityColor other) {
    final a = _lab;
    final b = other._lab;
    return math.sqrt(
      math.pow(a.$1 - b.$1, 2) +
          math.pow(a.$2 - b.$2, 2) +
          math.pow(a.$3 - b.$3, 2),
    );
  }

  static double _nearest(
    IdentityColor candidate,
    Iterable<IdentityColor> others,
  ) => others.map(candidate.distanceTo).reduce(math.min);

  (double, double, double) get _lab {
    double linear(int shift) {
      final channel = ((argb >> shift) & 0xff) / 255;
      return channel <= 0.04045
          ? channel / 12.92
          : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    }

    double labAxis(double value) => value > 216 / 24389
        ? math.pow(value, 1 / 3).toDouble()
        : (24389 / 27 * value + 16) / 116;
    final r = linear(16);
    final g = linear(8);
    final b = linear(0);
    final x = labAxis(
      (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047,
    );
    final y = labAxis(r * 0.2126729 + g * 0.7151522 + b * 0.0721750);
    final z = labAxis(
      (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883,
    );
    return (116 * y - 16, 500 * (x - y), 200 * (y - z));
  }
}
