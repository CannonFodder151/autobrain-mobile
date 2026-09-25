/// Shared pure helpers for the AutoBrain frontend.
///
/// No state, no I/O — safe to import from any feature module.
library;

/// Format a numeric value with locale-aware grouping.
String formatNumber(num value, {int decimals = 0}) {
  return value.toStringAsFixed(decimals);
}

/// Format a cost in Australian dollars.
String formatCurrency(num value, {String symbol = 'A\$'}) {
  return '$symbol${formatNumber(value, decimals: 2)}';
}

/// Clamp a value to the inclusive range [min, max].
T clamp<T extends num>(T value, T min, T max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/// Slugify a string for stable identifiers / URLs.
String slugify(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .trim()
      .replaceAll(RegExp(r'[\s_-]+'), '-');
}
