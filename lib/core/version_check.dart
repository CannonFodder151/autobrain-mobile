/// Pure dotted-version comparison for the x.y.z versioning scheme.
///
/// Compares component-wise (major > minor > patch). Missing components are
/// treated as 0, and the `+build` suffix on pubspec versions is ignored by
/// callers before this is reached.
library;

/// Returns true when [candidate] is newer than [installed].
bool isVersionNewerThan(String candidate, String installed) {
  final a = _parts(candidate);
  final b = _parts(installed);
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final av = i < a.length ? a[i] : 0;
    final bv = i < b.length ? b[i] : 0;
    if (av != bv) return av > bv;
  }
  return false;
}

/// Splits "x.y.z[+build]" into numeric parts; non-numeric segments count as 0.
List<int> _parts(String version) => version
    .split('.')
    .map((s) => int.tryParse(s.trim().split('+').first) ?? 0)
    .toList();
