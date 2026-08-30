import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scratch deeper cards', (WidgetTester t) async {
    final c = TextEditingController();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(padding: const EdgeInsets.all(16), children: [
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Channels'),
                SwitchListTile(title: Text('Push'), value: true, onChanged: (_) {}),
              ]))),
      const SizedBox(height: 12),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Service due alerts'),
                TextField(controller: c, decoration: InputDecoration(labelText: 'Alert X days before due (0 = off)')),
              ]))),
      const SizedBox(height: 12),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Discord webhook'),
                TextField(controller: c, decoration: InputDecoration(labelText: 'Discord webhook URL')),
              ]))),
      Card(child: Text('Servo spy alerts')),
    ]))));
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('SCRATCH2 channels=${find.text("Channels").evaluate().length}');
    // ignore: avoid_print
    print('SCRATCH2 discord=${find.text("Discord webhook").evaluate().length}');
    // ignore: avoid_print
    print('SCRATCH2 servo=${find.text("Servo spy alerts").evaluate().length}');
    // ignore: avoid_print
    print('SCRATCH2 cards=${t.widgetList(find.byType(Card)).length}');
  });
}
