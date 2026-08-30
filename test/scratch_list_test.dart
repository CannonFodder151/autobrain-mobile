import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scratch 4 cards', (WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(children: [
      Card(child: Text('a')),
      Card(child: Text('b')),
      Card(child: Text('c')),
      Card(child: Text('d')),
    ]))));
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('SCRATCH cards=${t.widgetList(find.byType(Card)).length}');
    // ignore: avoid_print
    print('SCRATCH a=${find.text("a").evaluate().length} c=${find.text("c").evaluate().length}');
  });
}
