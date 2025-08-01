import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../theme/theme_manager.dart';
import '../constants/relays.dart';
import '../services/data_service.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:async';

class RelayPage extends StatefulWidget {
  const RelayPage({super.key});

  @override
  State<RelayPage> createState() => _RelayPageState();
}

class _RelayPageState extends State<RelayPage> {
  final TextEditingController _addRelayController = TextEditingController();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  List<String> _relays = [];
  List<Map<String, dynamic>> _userRelays = [];
  bool _isLoading = true;
  bool _isAddingRelay = false;
  bool _isFetchingUserRelays = false;
  bool _isPublishingRelays = false;
  bool _isUsingUserRelays = false;

  @override
  void initState() {
    super.initState();
    _loadRelays();
  }

  @override
  void dispose() {
    _addRelayController.dispose();
    super.dispose();
  }

  Future<void> _loadRelays() async {
    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();

      // Check if user is using their own relays
      _isUsingUserRelays = prefs.getBool('using_user_relays') ?? false;

      // Load custom main relays or use defaults
      final customMainRelays = prefs.getStringList('custom_main_relays');
      final userRelaysJson = prefs.getString('user_relays');

      if (userRelaysJson != null) {
        final List<dynamic> decoded = jsonDecode(userRelaysJson);
        _userRelays = decoded.cast<Map<String, dynamic>>();
      }

      setState(() {
        _relays = customMainRelays ?? List.from(relaySetMainSockets);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _relays = List.from(relaySetMainSockets);
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading relays: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _publishRelays() async {
    if (!mounted) return;

    setState(() {
      _isPublishingRelays = true;
    });

    try {
      final npub = await _secureStorage.read(key: 'npub');
      if (npub == null) {
        _showSnackBar('Please set up your profile first', isError: true);
        return;
      }

      // Initialize DataService
      final dataService = DataService(npub: npub, dataType: DataType.profile);
      await dataService.initialize();

      // Prepare relay list for kind 10002 event
      List<List<String>> relayTags = [];

      // Add relays (read & write)
      for (String relay in _relays) {
        relayTags.add(['r', relay]);
      }

      // Create kind 10002 event
      final event = {
        'kind': 10002,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'tags': relayTags,
        'content': '',
        'pubkey': npub,
      };

      // For now, we'll simulate publishing by saving to local storage
      // In a real implementation, you would sign and publish the event to relays
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('published_relay_list', jsonEncode(event));

      _showSnackBar('Relay list prepared for publishing (${relayTags.length} relays)');

      // TODO: Implement actual event signing and publishing when crypto functions are available
      print('Event to publish: ${jsonEncode(event)}');

      await dataService.closeConnections();
    } catch (e) {
      print('Error publishing relays: $e');
      _showSnackBar('Error publishing relay list: ${e.toString()}', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isPublishingRelays = false;
        });
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : null,
        ),
      );
    }
  }

  Future<void> _fetchUserRelays() async {
    setState(() => _isFetchingUserRelays = true);

    try {
      final npub = await _secureStorage.read(key: 'npub');
      if (npub == null) {
        throw Exception('User not logged in');
      }

      final dataService = DataService(npub: npub, dataType: DataType.profile);
      await dataService.initialize();

      // Fetch kind 10002 event (relay list metadata)
      final userRelayList = await _fetchRelayListMetadata(dataService, npub);

      if (userRelayList.isNotEmpty) {
        setState(() {
          _userRelays = userRelayList;
        });

        // Save user relays to preferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_relays', jsonEncode(_userRelays));

        // Automatically use the fetched relays
        await _useUserRelays();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Found and applied ${_userRelays.length} relays from your profile')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No relay list found in your profile')),
          );
        }
      }

      await dataService.closeConnections();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching user relays: ${e.toString()}')),
        );
      }
    } finally {
      setState(() => _isFetchingUserRelays = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchRelayListMetadata(DataService dataService, String npub) async {
    final List<Map<String, dynamic>> relayList = [];

    try {
      // Create a WebSocket connection to fetch kind 10002 events
      for (final relayUrl in relaySetMainSockets) {
        WebSocket? ws;
        try {
          ws = await WebSocket.connect(relayUrl).timeout(const Duration(seconds: 5));

          final subscriptionId = DateTime.now().millisecondsSinceEpoch.toString();
          final request = jsonEncode([
            "REQ",
            subscriptionId,
            {
              "authors": [npub],
              "kinds": [10002],
              "limit": 1
            }
          ]);

          final completer = Completer<Map<String, dynamic>?>();
          late StreamSubscription sub;

          sub = ws.listen((event) {
            try {
              if (completer.isCompleted) return;
              final decoded = jsonDecode(event);
              if (decoded is List && decoded.length >= 2) {
                if (decoded[0] == 'EVENT' && decoded[1] == subscriptionId) {
                  completer.complete(decoded[2]);
                } else if (decoded[0] == 'EOSE' && decoded[1] == subscriptionId) {
                  completer.complete(null);
                }
              }
            } catch (e) {
              if (!completer.isCompleted) completer.complete(null);
            }
          }, onError: (error) {
            if (!completer.isCompleted) completer.complete(null);
          }, onDone: () {
            if (!completer.isCompleted) completer.complete(null);
          });

          if (ws.readyState == WebSocket.open) {
            ws.add(request);
          }

          final eventData = await completer.future.timeout(const Duration(seconds: 5), onTimeout: () => null);

          await sub.cancel();
          await ws.close();

          if (eventData != null) {
            final tags = eventData['tags'] as List<dynamic>? ?? [];

            for (final tag in tags) {
              if (tag is List && tag.isNotEmpty && tag[0] == 'r' && tag.length >= 2) {
                final relayUrl = tag[1] as String;
                String marker = '';

                if (tag.length >= 3 && tag[2] is String) {
                  marker = tag[2] as String;
                }

                // If no marker specified, it's both read and write
                if (marker.isEmpty) {
                  marker = 'read,write';
                }

                relayList.add({
                  'url': relayUrl,
                  'marker': marker,
                });
              }
            }

            // If we found relays, break out of the loop
            if (relayList.isNotEmpty) {
              break;
            }
          }
        } catch (e) {
          print('Error fetching from relay $relayUrl: $e');
          try {
            await ws?.close();
          } catch (_) {}
        }
      }
    } catch (e) {
      print('Error in _fetchRelayListMetadata: $e');
    }

    return relayList;
  }

  Future<void> _useUserRelays() async {
    if (_userRelays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No user relays available. Please fetch them first.')),
      );
      return;
    }

    try {
      // Extract relays that can be used for writing (main relays)
      final writeRelays = _userRelays
          .where((relay) => relay['marker'] == '' || relay['marker'].contains('write') || relay['marker'].contains('read,write'))
          .map((relay) => relay['url'] as String)
          .toList();

      setState(() {
        _relays = writeRelays.isNotEmpty ? writeRelays : _userRelays.map((relay) => relay['url'] as String).take(4).toList();
        _isUsingUserRelays = true;
      });

      await _saveRelays();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('using_user_relays', true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Now using your personal relays (${writeRelays.length} main relays)')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error applying user relays: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _stopUsingUserRelays() async {
    setState(() {
      _relays = List.from(relaySetMainSockets);
      _isUsingUserRelays = false;
    });

    await _saveRelays();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('using_user_relays', false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Switched back to default relays')),
      );
    }
  }

  Future<void> _saveRelays() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('custom_main_relays', _relays);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relays saved successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving relays: ${e.toString()}')),
        );
      }
    }
  }

  bool _isValidRelayUrl(String url) {
    final trimmed = url.trim();
    return trimmed.startsWith('wss://') || trimmed.startsWith('ws://');
  }

  Future<void> _addRelay(bool isMainRelay) async {
    final url = _addRelayController.text.trim();

    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a relay URL')),
      );
      return;
    }

    if (!_isValidRelayUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid WebSocket URL (wss:// or ws://)')),
      );
      return;
    }

    final targetList = _relays;

    if (targetList.contains(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Relay already exists in this category')),
      );
      return;
    }

    setState(() => _isAddingRelay = true);

    try {
      setState(() {
        targetList.add(url);
      });

      await _saveRelays();
      _addRelayController.clear();

      if (mounted) {
        Navigator.pop(context); // Close the dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relay added to Main list')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding relay: ${e.toString()}')),
        );
      }
    } finally {
      setState(() => _isAddingRelay = false);
    }
  }

  Future<void> _removeRelay(String url, bool isMainRelay) async {
    setState(() {
      _relays.remove(url);
    });

    await _saveRelays();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Relay removed successfully')),
      );
    }
  }

  Future<void> _resetToDefaults() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.colors.surface,
        title: Text('Reset to Defaults', style: TextStyle(color: context.colors.textPrimary)),
        content: Text(
          'This will reset all relays to their default values. Are you sure?',
          style: TextStyle(color: context.colors.textSecondary),
        ),
        actions: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: context.colors.surfaceTransparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.colors.borderLight),
              ),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: context.colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              Navigator.pop(context);
              setState(() {
                _relays = List.from(relaySetMainSockets);
                _isUsingUserRelays = false;
              });
              await _saveRelays();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Relays reset to defaults')),
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: context.colors.surfaceTransparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.colors.borderLight),
              ),
              child: Text(
                'Reset',
                style: TextStyle(
                  color: context.colors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddRelayDialog() {
    _addRelayController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.colors.surface,
        title: Text('Add New Relay', style: TextStyle(color: context.colors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _addRelayController,
              style: TextStyle(color: context.colors.textPrimary),
              decoration: InputDecoration(
                hintText: 'wss://relay.example.com',
                hintStyle: TextStyle(color: context.colors.textTertiary),
                filled: true,
                fillColor: context.colors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.colors.accent, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ],
        ),
        actions: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: context.colors.surfaceTransparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.colors.borderLight),
              ),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: context.colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: _isAddingRelay ? null : () => _addRelay(true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isAddingRelay ? context.colors.surface : context.colors.surfaceTransparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.colors.borderLight),
              ),
              child: Text(
                'Add Relay',
                style: TextStyle(
                  color: _isAddingRelay ? context.colors.textTertiary : context.colors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: context.colors.textPrimary),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Relay Management',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: context.colors.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // User Relays Section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_sync, color: context.colors.accent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Sync Relays',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: context.colors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Sync relays from your Nostr profile',
                  style: TextStyle(
                    fontSize: 14,
                    color: context.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _isFetchingUserRelays ? null : _fetchUserRelays,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: context.colors.surfaceTransparent,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: context.colors.borderLight),
                          ),
                          child: _isFetchingUserRelays
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(context.colors.textPrimary),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Fetching...',
                                      style: TextStyle(
                                        color: context.colors.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.download, size: 16, color: context.colors.textPrimary),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Fetch & Use',
                                      style: TextStyle(
                                        color: context.colors.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: _isPublishingRelays ? null : _publishRelays,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: context.colors.surfaceTransparent,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: context.colors.borderLight),
                          ),
                          child: _isPublishingRelays
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(context.colors.textPrimary),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Publishing...',
                                      style: TextStyle(
                                        color: context.colors.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.upload, size: 16, color: context.colors.textPrimary),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Publish',
                                      style: TextStyle(
                                        color: context.colors.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_isUsingUserRelays) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _stopUsingUserRelays,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Use Default Relays'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.colors.surface,
                        foregroundColor: context.colors.textPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: context.colors.border),
                        ),
                      ),
                    ),
                  ),
                ],
                if (_userRelays.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_userRelays.length} relays found in your profile',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colors.textTertiary,
                    ),
                  ),
                ],
                if (_isUsingUserRelays) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.colors.accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Currently using your personal relays',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.colors.accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Regular Action Buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _showAddRelayDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Relay'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.colors.accent,
                    foregroundColor: context.colors.background,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _resetToDefaults,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reset'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.colors.surface,
                  foregroundColor: context.colors.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: context.colors.border),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRelaySection(String title, List<String> relays, bool isMainRelay) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Icon(
                isMainRelay ? Icons.star : Icons.cloud,
                color: context.colors.accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: context.colors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: context.colors.accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${relays.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: context.colors.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (relays.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text(
              'No relays in this category',
              style: TextStyle(
                color: context.colors.textTertiary,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: relays.length,
            itemBuilder: (context, index) => _buildRelayTile(relays[index], isMainRelay),
            separatorBuilder: (_, __) => Divider(
              color: context.colors.border,
              height: 1,
            ),
          ),
      ],
    );
  }

  Widget _buildRelayTile(String relay, bool isMainRelay) {
    // Check if this relay is from user's personal relays
    final userRelay = _userRelays.firstWhere(
      (r) => r['url'] == relay,
      orElse: () => <String, dynamic>{},
    );
    final isUserRelay = userRelay.isNotEmpty;
    final marker = userRelay['marker'] as String? ?? '';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isUserRelay ? context.colors.accent.withOpacity(0.1) : context.colors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isUserRelay ? context.colors.accent.withOpacity(0.3) : context.colors.border),
        ),
        child: Icon(
          isUserRelay ? Icons.cloud_sync : Icons.router,
          color: isUserRelay ? context.colors.accent : context.colors.textSecondary,
          size: 20,
        ),
      ),
      title: Text(
        relay,
        style: TextStyle(
          color: context.colors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: isUserRelay
          ? Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.colors.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Synced',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.colors.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (marker.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.colors.surface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: context.colors.border),
                    ),
                    child: Text(
                      marker.replaceAll(',', ' • '),
                      style: TextStyle(
                        fontSize: 10,
                        color: context.colors.textSecondary,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            )
          : null,
      trailing: IconButton(
        icon: Icon(
          Icons.delete_outline,
          color: context.colors.textSecondary,
          size: 20,
        ),
        onPressed: () => _removeRelay(relay, isMainRelay),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: context.colors.background,
        body: Center(
          child: CircularProgressIndicator(color: context.colors.textPrimary),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.colors.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          _buildActionButtons(context),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildRelaySection('Relays', _relays, true),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
