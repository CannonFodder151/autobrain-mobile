import 'package:flutter_test/flutter_test.dart';

import 'package:autobrain/core/version_check.dart';

void main() {
  group('isVersionNewerThan', () {
    test('equal versions are not newer', () {
      expect(isVersionNewerThan('0.3.4', '0.3.4'), isFalse);
    });

    test('server patch ahead is newer', () {
      expect(isVersionNewerThan('0.3.5', '0.3.4'), isTrue);
    });

    test('server minor ahead is newer', () {
      expect(isVersionNewerThan('0.4.0', '0.3.4'), isTrue);
    });

    test('server major ahead is newer', () {
      expect(isVersionNewerThan('1.0.0', '0.3.4'), isTrue);
    });

    test('older server version is not newer', () {
      expect(isVersionNewerThan('0.3.3', '0.3.4'), isFalse);
    });

    test('installed build suffix is ignored (patch compare)', () {
      expect(isVersionNewerThan('0.3.4', '0.3.4+9'), isFalse);
      expect(isVersionNewerThan('0.3.5', '0.3.4+9'), isTrue);
    });

    test('missing components count as zero', () {
      expect(isVersionNewerThan('0.4', '0.3.9'), isTrue);
      expect(isVersionNewerThan('0.3', '0.3.4'), isFalse);
      expect(isVersionNewerThan('1', '0.99.99'), isTrue);
    });
  });
}
