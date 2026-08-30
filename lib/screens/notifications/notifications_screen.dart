import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_state.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.vehicleId});
  final String vehicleId;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  Map<String, dynamic>? _pref;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _saved;

  // Editing state
  bool _push = true;
  bool _email = true;
  bool _discord = false;
  int _dueDays = 7;
  int _dueKm = 500;
  int _fuelGapKm = 0;
  final _webhook = TextEditingController();
  final _daysCtrl = TextEditingController();
  final _kmCtrl = TextEditingController();
  final _fuelCtrl = TextEditingController();

  // Servo-spy watch list (per-user, vehicle-independent).
  List<Map<String, dynamic>> _watchlist = const [];
  bool _watchLoading = false;
  bool _adding = false;
  String? _watchError;
  final Set<String> _savingWatch = {};
  final String _markerState = 'NSW';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _webhook.dispose();
    _daysCtrl.dispose();
    _kmCtrl.dispose();
    _fuelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _watchError = null;
    });
    await _loadPrefs();
    await _loadWatchlist();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadPrefs() async {
    final api = context.read<AuthState>().api;
    try {
      final p = await api.get(
              '/vehicles/${widget.vehicleId}/notifications')
          as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _pref = p;
          _push = p['push_enabled'] as bool? ?? true;
          _email = p['email_enabled'] as bool? ?? true;
          _discord = p['discord_enabled'] as bool? ?? false;
          _dueDays = (p['service_due_days'] as num?)?.toInt() ?? 7;
          _dueKm = (p['service_due_km'] as num?)?.toInt() ?? 500;
          _fuelGapKm = (p['fuel_gap_km'] as num?)?.toInt() ?? 0;
          _webhook.text = (p['discord_webhook_url'] as String?) ?? '';
          _daysCtrl.text = '$_dueDays';
          _kmCtrl.text = '$_dueKm';
          _fuelCtrl.text = _fuelGapKm > 0 ? '$_fuelGapKm' : '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadWatchlist() async {
    final api = context.read<AuthState>().api;
    if (mounted) setState(() => _watchLoading = true);
    try {
      final data = (await api.get('/fuel-prices/watchlist') as List)
          .cast<Map<String, dynamic>>();
      if (mounted) setState(() => _watchlist = data);
    } catch (e) {
      if (mounted) setState(() => _watchError = '$e');
    } finally {
      if (mounted) setState(() => _watchLoading = false);
    }
  }

  Future<void> _addFavourite(Map<String, dynamic> marker) async {
    final api = context.read<AuthState>().api;
    final body = {
      'state': marker['state'] as String? ?? _markerState,
      'station_code': marker['station_code'],
      'fuel_type': marker['fuel_type'],
      'direction': 'both',
      'threshold_pct': 5.0,
    };
    try {
      await api.post('/fuel-prices/watchlist', body);
      await _loadWatchlist();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add: $e')));
      }
    }
  }

  Future<void> _updateFavourite(
      String id, String direction, double threshold) async {
    final api = context.read<AuthState>().api;
    final item = _watchlist.firstWhere((e) => e['id'] == id);
    final body = {
      'state': item['state'],
      'station_code': item['station_code'],
      'fuel_type': item['fuel_type'],
      'direction': direction,
      'threshold_pct': threshold,
    };
    setState(() => _savingWatch.add(id));
    try {
      await api.post('/fuel-prices/watchlist', body);
      await _loadWatchlist();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Favourite updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingWatch.remove(id));
    }
  }

  Future<void> _removeFavourite(String id) async {
    final api = context.read<AuthState>().api;
    setState(() => _savingWatch.add(id));
    try {
      await api.delete('/fuel-prices/watchlist/$id');
      await _loadWatchlist();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not remove: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingWatch.remove(id));
    }
  }

  Future<void> _openAddFavourite() async {
    final api = context.read<AuthState>().api;
    setState(() => _adding = true);
    try {
      final markers = (await api.get('/fuel-prices?state=$_markerState') as List)
          .cast<Map<String, dynamic>>();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => AddFavouriteSheet(
          markers: markers,
          onPick: (m) async {
            Navigator.of(context).pop();
            await _addFavourite(m);
          },
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not load servos: $e')));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _save() async {
    final api = context.read<AuthState>().api;
    setState(() {
      _saving = true;
      _saved = null;
      _error = null;
    });
    try {
      final body = {
        'push_enabled': _push,
        'email_enabled': _email,
        'discord_enabled': _discord,
        'service_due_days': int.tryParse(_daysCtrl.text) ?? 7,
        'service_due_km': int.tryParse(_kmCtrl.text) ?? 500,
        'fuel_gap_km': int.tryParse(_fuelCtrl.text) ?? 0,
        'discord_webhook_url': _webhook.text.trim().isEmpty
            ? null
            : _webhook.text.trim(),
      };
      await api.put('/vehicles/${widget.vehicleId}/notifications', body);
      if (mounted) setState(() => _saved = 'Settings saved');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Channels',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Push notifications'),
                            subtitle: const Text('In-app / device notifications'),
                            value: _push,
                            onChanged: (v) => setState(() => _push = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Email'),
                            subtitle: const Text(
                                'Sent from the system email account'),
                            value: _email,
                            onChanged: (v) => setState(() => _email = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Discord'),
                            subtitle: const Text(
                                'Via your own Discord webhook'),
                            value: _discord,
                            onChanged: (v) => setState(() => _discord = v),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Service due alerts',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            'Notify when a scheduled service is coming up — '
                            'by days until the due date, by distance to the next '
                            'due km, or both. Evaluated when services and fuel '
                            'data are added.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _daysCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Alert X days before due (0 = off)',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _kmCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Alert X km before due (0 = off)',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _fuelCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText:
                                  'Fuel log reminder after X km gap (0 = off)',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Discord webhook',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            'Paste a Discord webhook URL to receive alerts there. '
                            'You create the webhook in your Discord server — '
                            'AutoBrain never stores or shares your credentials.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _webhook,
                            decoration: const InputDecoration(
                              labelText: 'Discord webhook URL',
                              hintText: 'https://discord.com/api/webhooks/...',
                            ),
                          ),
                        ],
                      ),
                    ),
                   ),
                   Card(
                     child: Padding(
                       padding: const EdgeInsets.all(16),
                       child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           Text('Servo spy alerts',
                               style: Theme.of(context).textTheme.titleMedium),
                           const SizedBox(height: 4),
                           Text(
                             'Watch your favourite servos and get a price-move '
                             'alert through your existing channels (email, '
                             'Discord, push) when fuel moves past your '
                             'threshold.',
                             style: Theme.of(context).textTheme.bodySmall,
                           ),
                           const SizedBox(height: 12),
                           if (_watchLoading)
                             const Center(child: CircularProgressIndicator())
                           else if (_watchlist.isEmpty)
                             const Text('No favourites yet.')
                           else
                             for (final item in _watchlist)
                               WatchlistTile(
                                 item: item,
                                 saving: _savingWatch.contains(item['id']),
                                 onSave: _updateFavourite,
                                 onRemove: _removeFavourite,
                               ),
                           const SizedBox(height: 12),
                           FilledButton.tonalIcon(
                             onPressed: _adding ? null : _openAddFavourite,
                             icon: _adding
                                 ? const SizedBox(
                                     height: 16,
                                     width: 16,
                                     child: CircularProgressIndicator(
                                         strokeWidth: 2),
                                   )
                                 : const Icon(Icons.add),
                             label: const Text('Add favourite'),
                           ),
                           if (_watchError != null) ...[
                             const SizedBox(height: 8),
                             Text(_watchError!,
                                 style: TextStyle(color: Colors.red.shade600)),
                           ],
                         ],
                       ),
                     ),
                   ),
                   const SizedBox(height: 12),
                   if (_error != null) ...[
                     const SizedBox(height: 12),
                     Text(_error!,
                         style: TextStyle(color: Colors.red.shade600)),
                   ],
                  if (_saved != null) ...[
                    const SizedBox(height: 12),
                    Text(_saved!,
                        style: TextStyle(color: Colors.green.shade700)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save notification settings'),
                  ),
                   ],
                ),
              ),
    );
  }
}

class WatchlistTile extends StatefulWidget {
  const WatchlistTile({
    super.key,
    required this.item,
    required this.onSave,
    required this.onRemove,
    required this.saving,
  });
  final Map<String, dynamic> item;
  final Future<void> Function(String id, String direction, double threshold)
      onSave;
  final Future<void> Function(String id) onRemove;
  final bool saving;

  @override
  State<WatchlistTile> createState() => _WatchlistTileState();
}

class _WatchlistTileState extends State<WatchlistTile> {
  late String _direction = widget.item['direction'] as String? ?? 'both';
  late final TextEditingController _thrCtrl = TextEditingController(
      text: '${(widget.item['threshold_pct'] as num?)?.toDouble() ?? 5.0}');

  @override
  void dispose() {
    _thrCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.item['id'] as String;
    final brand = '${widget.item['brand'] ?? ''}';
    final name = '${widget.item['station_name'] ?? ''}';
    final fuel = '${widget.item['fuel_type'] ?? ''}';
    final title = [brand, name].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove favourite',
                  onPressed: widget.saving
                      ? null
                      : () => widget.onRemove(id),
                ),
              ],
            ),
            Text(fuel, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            const Text('Alert when price:'),
            SegmentedButton<String>(
              showSelectedIcon: false,
              selected: {_direction},
              onSelectionChanged: (s) => setState(() => _direction = s.first),
              segments: const [
                ButtonSegment(value: 'up', label: Text('Rises')),
                ButtonSegment(value: 'down', label: Text('Drops')),
                ButtonSegment(value: 'both', label: Text('Either')),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _thrCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Threshold % (must be > 0)',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: widget.saving
                    ? null
                    : () {
                        final t = double.tryParse(_thrCtrl.text);
                        if (t == null || t <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Threshold must be greater than 0')),
                          );
                          return;
                        }
                        widget.onSave(id, _direction, t);
                      },
                child: const Text('Update'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddFavouriteSheet extends StatefulWidget {
  const AddFavouriteSheet({
    super.key,
    required this.markers,
    required this.onPick,
  });
  final List<Map<String, dynamic>> markers;
  final Future<void> Function(Map<String, dynamic>) onPick;

  @override
  State<AddFavouriteSheet> createState() => _AddFavouriteSheetState();
}

class _AddFavouriteSheetState extends State<AddFavouriteSheet> {
  final _q = TextEditingController();
  late List<Map<String, dynamic>> _filtered = widget.markers;

  @override
  void initState() {
    super.initState();
    _q.addListener(_apply);
  }

  void _apply() {
    final q = _q.text.toLowerCase();
    setState(() => _filtered = q.isEmpty
        ? widget.markers
        : widget.markers.where((m) {
            final brand = '${m['brand'] ?? ''}'.toLowerCase();
            final name = '${m['station_name'] ?? ''}'.toLowerCase();
            final fuel = '${m['fuel_type'] ?? ''}'.toLowerCase();
            return brand.contains(q) || name.contains(q) || fuel.contains(q);
          }).toList());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _q,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search servos',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                for (final m in _filtered)
                  ListTile(
                    title: Text([
                      '${m['brand'] ?? ''}',
                      '${m['station_name'] ?? ''}'
                    ].where((s) => s.isNotEmpty).join(' · ')),
                    subtitle: Text('${m['fuel_type'] ?? ''}'
                        '${m['price'] != null ? ' · \$${m['price']}' : ''}'),
                    onTap: () => widget.onPick(m),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
