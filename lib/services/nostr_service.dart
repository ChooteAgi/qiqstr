import 'dart:convert';
import 'dart:collection';
import 'package:nostr/nostr.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

/// Service that encapsulates all nostr package functionality
/// This allows for easy replacement of the nostr package in the future
class NostrService {
  static final Uuid _uuid = Uuid();

  // Event caching for performance
  static final Map<String, Event> _eventCache = {};
  static final Map<String, Filter> _filterCache = {};
  static final Map<String, Request> _requestCache = {};
  static const int _maxCacheSize = 1000;

  // Performance metrics
  static int _eventsCreated = 0;
  static int _filtersCreated = 0;
  static int _requestsCreated = 0;
  static int _cacheHits = 0;
  static int _cacheMisses = 0;

  // Batch processing for multiple operations
  static final Queue<Map<String, dynamic>> _batchQueue = Queue();
  static bool _isBatchProcessing = false;

  // Event creation methods with caching
  static Event createNoteEvent({
    required String content,
    required String privateKey,
    List<List<String>>? tags,
  }) {
    final cacheKey = _generateEventCacheKey(1, content, privateKey, tags);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 1,
      tags: tags ?? [],
      content: content,
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  static Event createReactionEvent({
    required String targetEventId,
    required String content,
    required String privateKey,
  }) {
    final tags = [
      ['e', targetEventId]
    ];
    final cacheKey = _generateEventCacheKey(7, content, privateKey, tags);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 7,
      tags: tags,
      content: content,
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  static Event createReplyEvent({
    required String content,
    required String privateKey,
    required List<List<String>> tags,
  }) {
    final cacheKey = _generateEventCacheKey(1, content, privateKey, tags);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 1,
      tags: tags,
      content: content,
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  static Event createRepostEvent({
    required String noteId,
    required String noteAuthor,
    required String content,
    required String privateKey,
  }) {
    final tags = [
      ['e', noteId],
      ['p', noteAuthor],
    ];

    final cacheKey = _generateEventCacheKey(6, content, privateKey, tags);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 6,
      tags: tags,
      content: content,
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  static Event createProfileEvent({
    required Map<String, dynamic> profileContent,
    required String privateKey,
  }) {
    final content = jsonEncode(profileContent);
    final cacheKey = _generateEventCacheKey(0, content, privateKey, []);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 0,
      tags: [],
      content: content,
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  static Event createFollowEvent({
    required List<String> followingPubkeys,
    required String privateKey,
  }) {
    final tags = followingPubkeys.map((pubkey) => ['p', pubkey, '']).toList();
    final cacheKey = _generateEventCacheKey(3, "", privateKey, tags);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 3,
      tags: tags,
      content: "",
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  static Event createZapRequestEvent({
    required List<List<String>> tags,
    required String content,
    required String privateKey,
  }) {
    final cacheKey = _generateEventCacheKey(9734, content, privateKey, tags);

    if (_eventCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _eventCache[cacheKey]!;
    }

    _cacheMisses++;
    _eventsCreated++;

    final event = Event.from(
      kind: 9734,
      tags: tags,
      content: content,
      privkey: privateKey,
    );

    _addToEventCache(cacheKey, event);
    return event;
  }

  // Filter creation methods with caching
  static Filter createNotesFilter({
    List<String>? authors,
    List<int>? kinds,
    int? limit,
    int? since,
    int? until,
  }) {
    final cacheKey = _generateFilterCacheKey('notes', {
      'authors': authors,
      'kinds': kinds ?? [1, 6],
      'limit': limit,
      'since': since,
      'until': until,
    });

    if (_filterCache.containsKey(cacheKey)) {
      _cacheHits++;
      return _filterCache[cacheKey]!;
    }

    _cacheMisses++;
    _filtersCreated++;

    final filter = Filter(
      authors: authors,
      kinds: kinds ?? [1, 6],
      limit: limit,
      since: since,
      until: until,
    );

    _addToFilterCache(cacheKey, filter);
    return filter;
  }

  static Filter createProfileFilter({
    required List<String> authors,
    int? limit,
  }) {
    return Filter(
      authors: authors,
      kinds: [0],
      limit: limit,
    );
  }

  static Filter createFollowingFilter({
    required List<String> authors,
    int? limit,
  }) {
    return Filter(
      authors: authors,
      kinds: [3],
      limit: limit,
    );
  }

  static Filter createReactionFilter({
    required List<String> eventIds,
    int? limit,
    int? since,
  }) {
    return Filter(
      kinds: [7],
      e: eventIds,
      limit: limit,
      since: since,
    );
  }

  static Filter createReplyFilter({
    required List<String> eventIds,
    int? limit,
    int? since,
  }) {
    return Filter(
      kinds: [1],
      e: eventIds,
      limit: limit,
      since: since,
    );
  }

  static Filter createRepostFilter({
    required List<String> eventIds,
    int? limit,
    int? since,
  }) {
    return Filter(
      kinds: [6],
      e: eventIds,
      limit: limit,
      since: since,
    );
  }

  static Filter createZapFilter({
    required List<String> eventIds,
    int? limit,
    int? since,
  }) {
    return Filter(
      kinds: [9735],
      e: eventIds,
      limit: limit,
      since: since,
    );
  }

  static Filter createNotificationFilter({
    required List<String> pubkeys,
    List<int>? kinds,
    int? since,
    int? limit,
  }) {
    return Filter(
      p: pubkeys,
      kinds: kinds ?? [1, 6, 7, 9735],
      since: since,
      limit: limit,
    );
  }

  static Filter createEventByIdFilter({
    required List<String> eventIds,
  }) {
    return Filter(
      ids: eventIds,
    );
  }

  static Filter createCombinedInteractionFilter({
    required List<String> eventIds,
    int? limit,
  }) {
    return Filter(
      kinds: [7, 1, 6, 9735],
      e: eventIds,
      limit: limit,
    );
  }

  // Request creation methods
  static Request createRequest(Filter filter) {
    final uuid = generateUUID();
    final cacheKey = 'single_${filter.hashCode}';

    if (_requestCache.containsKey(cacheKey)) {
      _cacheHits++;
      // Create new request with fresh UUID but same filter
      return Request(uuid, [filter]);
    }

    _cacheMisses++;
    _requestsCreated++;

    final request = Request(uuid, [filter]);
    _addToRequestCache(cacheKey, request);
    return request;
  }

  static Request createMultiFilterRequest(List<Filter> filters) {
    final uuid = generateUUID();
    final cacheKey = 'multi_${filters.map((f) => f.hashCode).join('_')}';

    if (_requestCache.containsKey(cacheKey)) {
      _cacheHits++;
      // Create new request with fresh UUID but same filters
      return Request(uuid, filters);
    }

    _cacheMisses++;
    _requestsCreated++;

    final request = Request(uuid, filters);
    _addToRequestCache(cacheKey, request);
    return request;
  }

  // Utility methods
  static String generateUUID() => _uuid.v4().replaceAll('-', '');

  static String serializeEvent(Event event) => event.serialize();

  static String serializeRequest(Request request) => request.serialize();

  static Map<String, dynamic> eventToJson(Event event) => event.toJson();

  // Zap request helpers
  static List<List<String>> createZapRequestTags({
    required List<String> relays,
    required String amountMillisats,
    required String recipientPubkey,
    String? lnurlBech32,
    String? noteId,
  }) {
    final List<List<String>> tags = [
      ['relays', ...relays],
      ['amount', amountMillisats],
      ['p', recipientPubkey],
    ];

    if (lnurlBech32 != null && lnurlBech32.isNotEmpty) {
      tags.add(['lnurl', lnurlBech32]);
    }

    if (noteId != null && noteId.isNotEmpty) {
      tags.add(['e', noteId]);
    }

    return tags;
  }

  // Reply tags helpers
  static List<List<String>> createReplyTags({
    required String rootId,
    String? replyId,
    required String parentAuthor,
    required List<String> relayUrls,
  }) {
    List<List<String>> tags = [];

    if (replyId != null && replyId != rootId) {
      tags.add(['e', rootId, '', 'root']);
      tags.add(['e', replyId, '', 'reply']);
    } else {
      tags.add(['e', rootId, '', 'root']);
    }

    tags.add(['p', parentAuthor, '', 'mention']);

    for (final relayUrl in relayUrls) {
      tags.add(['r', relayUrl]);
    }

    return tags;
  }

  // Hash calculation for media uploads
  static String calculateSha256Hash(List<int> fileBytes) {
    return sha256.convert(fileBytes).toString();
  }

  // MIME type detection
  static String detectMimeType(String filePath) {
    final lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return 'image/jpeg';
    } else if (lowerPath.endsWith('.png')) {
      return 'image/png';
    } else if (lowerPath.endsWith('.gif')) {
      return 'image/gif';
    } else if (lowerPath.endsWith('.mp4')) {
      return 'video/mp4';
    }
    return 'application/octet-stream';
  }

  // Batch processing methods
  static void addToBatch(String operation, Map<String, dynamic> params) {
    _batchQueue.add({
      'operation': operation,
      'params': params,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Process batch if it gets large
    if (_batchQueue.length >= 10) {
      processBatch();
    }
  }

  static List<dynamic> processBatch() {
    if (_isBatchProcessing || _batchQueue.isEmpty) return [];

    _isBatchProcessing = true;
    final results = <dynamic>[];

    try {
      while (_batchQueue.isNotEmpty && results.length < 20) {
        final item = _batchQueue.removeFirst();
        final operation = item['operation'] as String;
        final params = item['params'] as Map<String, dynamic>;

        switch (operation) {
          case 'createNoteEvent':
            results.add(createNoteEvent(
              content: params['content'],
              privateKey: params['privateKey'],
              tags: params['tags'],
            ));
            break;
          case 'createReactionEvent':
            results.add(createReactionEvent(
              targetEventId: params['targetEventId'],
              content: params['content'],
              privateKey: params['privateKey'],
            ));
            break;
          case 'createFilter':
            results.add(createNotesFilter(
              authors: params['authors'],
              kinds: params['kinds'],
              limit: params['limit'],
              since: params['since'],
              until: params['until'],
            ));
            break;
        }
      }
    } finally {
      _isBatchProcessing = false;
    }

    return results;
  }

  // Cache management methods
  static String _generateEventCacheKey(int kind, String content, String privateKey, List<List<String>>? tags) {
    final tagsStr = tags?.map((tag) => tag.join(':')).join('|') ?? '';
    return 'event_${kind}_${content.hashCode}_${privateKey.hashCode}_${tagsStr.hashCode}';
  }

  static String _generateFilterCacheKey(String type, Map<String, dynamic> params) {
    return 'filter_${type}_${params.hashCode}';
  }

  static void _addToEventCache(String key, Event event) {
    if (_eventCache.length >= _maxCacheSize) {
      _evictOldestCacheEntry(_eventCache);
    }
    _eventCache[key] = event;
  }

  static void _addToFilterCache(String key, Filter filter) {
    if (_filterCache.length >= _maxCacheSize) {
      _evictOldestCacheEntry(_filterCache);
    }
    _filterCache[key] = filter;
  }

  static void _addToRequestCache(String key, Request request) {
    if (_requestCache.length >= _maxCacheSize) {
      _evictOldestCacheEntry(_requestCache);
    }
    _requestCache[key] = request;
  }

  static void _evictOldestCacheEntry(Map<String, dynamic> cache) {
    if (cache.isNotEmpty) {
      final firstKey = cache.keys.first;
      cache.remove(firstKey);
    }
  }

  // Enhanced statistics and monitoring
  static Map<String, dynamic> getNostrStats() {
    final hitRate = _cacheHits + _cacheMisses > 0 ? (_cacheHits / (_cacheHits + _cacheMisses) * 100).toStringAsFixed(1) : '0.0';

    return {
      'eventsCreated': _eventsCreated,
      'filtersCreated': _filtersCreated,
      'requestsCreated': _requestsCreated,
      'cacheHits': _cacheHits,
      'cacheMisses': _cacheMisses,
      'hitRate': '$hitRate%',
      'eventCacheSize': _eventCache.length,
      'filterCacheSize': _filterCache.length,
      'requestCacheSize': _requestCache.length,
      'batchQueueSize': _batchQueue.length,
      'isBatchProcessing': _isBatchProcessing,
    };
  }

  // Cache cleanup methods
  static void clearEventCache() {
    _eventCache.clear();
  }

  static void clearFilterCache() {
    _filterCache.clear();
  }

  static void clearRequestCache() {
    _requestCache.clear();
  }

  static void clearAllCaches() {
    clearEventCache();
    clearFilterCache();
    clearRequestCache();
    _batchQueue.clear();
  }

  // Optimized batch creation methods
  static List<Event> createMultipleNoteEvents(List<Map<String, dynamic>> eventData) {
    return eventData
        .map((data) => createNoteEvent(
              content: data['content'],
              privateKey: data['privateKey'],
              tags: data['tags'],
            ))
        .toList();
  }

  static List<Filter> createMultipleFilters(List<Map<String, dynamic>> filterData) {
    return filterData
        .map((data) => createNotesFilter(
              authors: data['authors'],
              kinds: data['kinds'],
              limit: data['limit'],
              since: data['since'],
              until: data['until'],
            ))
        .toList();
  }

  // Performance optimization: pre-warm cache with common filters
  static void preWarmCache() {
    // Pre-create common filters
    createNotesFilter(kinds: [1, 6], limit: 50);
    createProfileFilter(authors: [], limit: 100);
    createReactionFilter(eventIds: [], limit: 100);
    createReplyFilter(eventIds: [], limit: 100);
    createNotificationFilter(pubkeys: [], limit: 50);
  }
}
