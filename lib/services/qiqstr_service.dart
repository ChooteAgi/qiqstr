import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'package:hive/hive.dart';
import 'package:nostr/nostr.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/user_model.dart';
import '../models/note_model.dart';
import '../models/reaction_model.dart';
import '../models/reply_model.dart';
import '../models/repost_model.dart';

enum DataType { Feed, Profile, Note }

enum MessageType { NewNotes, CacheLoad, Error, Close }

class IsolateMessage {
  final MessageType type;
  final dynamic data;
  IsolateMessage(this.type, this.data);
}

class CachedProfile {
  final Map<String, String> data;
  final DateTime fetchedAt;
  CachedProfile(this.data, this.fetchedAt);
}

class WebSocketManager {
  final List<String> relayUrls;
  final Map<String, WebSocket> _webSockets = {};
  final Duration connectionTimeout;
  bool _isClosed = false;

  WebSocketManager({
    required this.relayUrls,
    this.connectionTimeout = const Duration(seconds: 1),
  });

  List<WebSocket> get activeSockets => _webSockets.values.toList();
  bool get isConnected => _webSockets.isNotEmpty;

  Future<void> connectRelays(
    List<String> targetNpubs, {
    Function(dynamic event, String relayUrl)? onEvent,
    Function(String relayUrl)? onDisconnected,
  }) async {
    await Future.wait(relayUrls.map((relayUrl) async {
      if (_isClosed) return;
      if (!_webSockets.containsKey(relayUrl) ||
          _webSockets[relayUrl]?.readyState == WebSocket.closed) {
        try {
          final rawWs =
              await WebSocket.connect(relayUrl).timeout(connectionTimeout);
          final wsBroadcast = rawWs.asBroadcastStream();
          _webSockets[relayUrl] = rawWs;
          wsBroadcast.listen(
            (event) => onEvent?.call(event, relayUrl),
            onDone: () {
              _webSockets.remove(relayUrl);
              onDisconnected?.call(relayUrl);
            },
            onError: (error) {
              _webSockets.remove(relayUrl);
              onDisconnected?.call(relayUrl);
            },
          );
        } catch (e) {
          print('Error connecting to relay $relayUrl: $e');
          _webSockets.remove(relayUrl);
        }
      }
    }));
  }

  Future<void> executeOnActiveSockets(
      FutureOr<void> Function(WebSocket ws) action) async {
    final futures = _webSockets.values.map((ws) async {
      if (ws.readyState == WebSocket.open) await action(ws);
    });
    await Future.wait(futures);
  }

  Future<void> broadcast(String message) async {
    await executeOnActiveSockets((ws) async => ws.add(message));
  }

  void reconnectRelay(String relayUrl, List<String> targetNpubs,
      {int attempt = 1, Function(String relayUrl)? onReconnected}) {
    if (_isClosed) return;
    const int maxAttempts = 5;
    if (attempt > maxAttempts) return;

    int delaySeconds = _calculateBackoffDelay(attempt);
    Timer(Duration(seconds: delaySeconds), () async {
      if (_isClosed) return;
      try {
        final rawWs =
            await WebSocket.connect(relayUrl).timeout(connectionTimeout);
        final wsBroadcast = rawWs.asBroadcastStream();
        if (_isClosed) {
          await rawWs.close();
          return;
        }
        _webSockets[relayUrl] = rawWs;
        wsBroadcast.listen((event) {}, onDone: () {
          _webSockets.remove(relayUrl);
          reconnectRelay(relayUrl, targetNpubs, attempt: attempt + 1);
        }, onError: (error) {
          _webSockets.remove(relayUrl);
          reconnectRelay(relayUrl, targetNpubs, attempt: attempt + 1);
        });
        onReconnected?.call(relayUrl);
        print('Reconnected to relay: $relayUrl');
      } catch (e) {
        print('Error reconnecting to relay $relayUrl (Attempt $attempt): $e');
        reconnectRelay(relayUrl, targetNpubs, attempt: attempt + 1);
      }
    });
  }

  int _calculateBackoffDelay(int attempt) {
    const int baseDelay = 2;
    const int maxDelay = 32;
    int delay = (baseDelay * pow(2, attempt - 1)).toInt().clamp(1, maxDelay);
    int jitter = Random().nextInt(2);
    return delay + jitter;
  }

  Future<void> closeConnections() async {
    _isClosed = true;
    await Future.wait(_webSockets.values.map((ws) async => await ws.close()));
    _webSockets.clear();
  }
}

class DataService {
  final String npub;
  final DataType dataType;
  final Function(NoteModel)? onNewNote;
  final Function(String, List<ReactionModel>)? onReactionsUpdated;
  final Function(String, List<ReplyModel>)? onRepliesUpdated;
  final Function(String, int)? onReactionCountUpdated;
  final Function(String, int)? onReplyCountUpdated;
  final Function(String, List<RepostModel>)? onRepostsUpdated;
  final Function(String, int)? onRepostCountUpdated;

  List<NoteModel> notes = [];
  final Set<String> noteKeys = {};

  final Map<String, List<ReactionModel>> reactionsMap = {};
  final Map<String, List<ReplyModel>> repliesMap = {};
  final Map<String, List<RepostModel>> repostsMap = {};

  final Map<String, CachedProfile> profileCache = {};

  Box<UserModel>? usersBox;
  Box<NoteModel>? notesBox;
  Box<ReactionModel>? reactionsBox;
  Box<ReplyModel>? repliesBox;
  Box<RepostModel>? repostsBox;

  late WebSocketManager _socketManager;
  bool _isInitialized = false;
  bool _isClosed = false;

  Timer? _checkNewNotesTimer;
  Timer? _cacheCleanupTimer;
  final int currentLimit = 75;

  final Map<String, Completer<Map<String, String>>> _pendingProfileRequests =
      {};
  final Map<String, String> _profileSubscriptionIds = {};

  late ReceivePort _receivePort;
  late Isolate _isolate;
  late SendPort _sendPort;
  final Completer<void> _sendPortReadyCompleter = Completer<void>();

  Function(List<NoteModel>)? _onCacheLoad;

  final Uuid _uuid = Uuid();

  final Duration profileCacheTTL = const Duration(hours: 24);
  final Duration cacheCleanupInterval = const Duration(hours: 12);

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  DataService({
    required this.npub,
    required this.dataType,
    this.onNewNote,
    this.onReactionsUpdated,
    this.onRepliesUpdated,
    this.onReactionCountUpdated,
    this.onReplyCountUpdated,
    this.onRepostsUpdated,
    this.onRepostCountUpdated,
  });

  int get connectedRelaysCount => _socketManager.activeSockets.length;

  String _noteUniqueKey(NoteModel note) {
    return note.isRepost && note.repostTimestamp != null
        ? '${note.id}_${note.repostTimestamp!.millisecondsSinceEpoch}'
        : note.id;
  }

  Future<void> initialize() async {
    notesBox =
        await _openHiveBox<NoteModel>('notes_${dataType.toString()}_$npub');
    print('[DataService] Hive notes box opened successfully.');

    await Future.wait([
      _openHiveBox<ReactionModel>('reactions_${dataType.toString()}_$npub')
          .then((box) {
        reactionsBox = box;
        print('[DataService] Hive reactions box opened successfully.');
      }),
      _openHiveBox<ReplyModel>('replies_${dataType.toString()}_$npub')
          .then((box) {
        repliesBox = box;
        print('[DataService] Hive replies box opened successfully.');
      }),
      _openHiveBox<RepostModel>('reposts_${dataType.toString()}_$npub')
          .then((box) {
        repostsBox = box;
        print('[DataService] Hive reposts box opened successfully.');
      }),
      _openHiveBox<UserModel>('users').then((box) {
        usersBox = box;
        print('[DataService] Hive users box opened successfully.');
      }),
    ]);

    _socketManager = WebSocketManager(relayUrls: [
      'wss://relay.damus.io',
      'wss://nos.lol',
      'wss://relay.primal.net',
      'wss://vitor.nostr1.com',
      'wss://eu.purplerelay.com',
    ]);

    await Future.wait([
      _initializeIsolate(),
      _socketManager.connectRelays(
        [],
        onEvent: (event, relayUrl) => _handleEvent(event, []),
        onDisconnected: (relayUrl) =>
            _socketManager.reconnectRelay(relayUrl, []),
      ),
    ]);

    await loadNotesFromCache((loadedNotes) {
      print('[DataService] Cache loaded with ${loadedNotes.length} notes.');
    });

    if (notes.isNotEmpty) {
      List<String> noteKeyList =
          notes.map((note) => _noteUniqueKey(note)).toList();
      await Future.wait([
        fetchReactionsForNotes(noteKeyList),
        fetchRepliesForNotes(noteKeyList),
        fetchRepostsForNotes(noteKeyList),
      ]);
      print(
          '[DataService] Fetched reactions, replies, and reposts for cached notes.');
    }

    await _fetchUserData();

    _startCacheCleanup();
    _isInitialized = true;
  }

  Future<Box<T>> _openHiveBox<T>(String boxName) async {
    if (Hive.isBoxOpen(boxName)) {
      return Hive.box<T>(boxName);
    } else {
      return await Hive.openBox<T>(boxName);
    }
  }

  Future<void> _initializeIsolate() async {
    _receivePort = ReceivePort();
    _isolate =
        await Isolate.spawn(_dataProcessorEntryPoint, _receivePort.sendPort);

    _receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        if (!_sendPortReadyCompleter.isCompleted) {
          _sendPortReadyCompleter.complete();
          print('[DataService] Isolate initialized successfully.');
        }
      } else if (message is IsolateMessage) {
        switch (message.type) {
          case MessageType.NewNotes:
            _handleNewNotes(message.data);
            break;
          case MessageType.CacheLoad:
            _handleCacheLoad(message.data);
            break;
          case MessageType.Error:
            print('[DataService ERROR] Isolate error: ${message.data}');
            break;
          case MessageType.Close:
            print('[DataService] Isolate received close message.');
            break;
        }
      }
    });
  }

  static void _dataProcessorEntryPoint(SendPort sendPort) {
    final ReceivePort isolateReceivePort = ReceivePort();
    sendPort.send(isolateReceivePort.sendPort);

    isolateReceivePort.listen((message) {
      if (message is IsolateMessage) {
        switch (message.type) {
          case MessageType.CacheLoad:
            _processCacheLoad(message.data, sendPort);
            break;
          case MessageType.NewNotes:
            _processNewNotes(message.data, sendPort);
            break;
          case MessageType.Close:
            isolateReceivePort.close();
            break;
          case MessageType.Error:
            sendPort.send(IsolateMessage(MessageType.Error, message.data));
            break;
        }
      } else if (message is String && message == 'close') {
        isolateReceivePort.close();
      }
    });
  }

  static void _processCacheLoad(String data, SendPort sendPort) {
    try {
      final List<dynamic> jsonData = json.decode(data);
      final List<NoteModel> parsedNotes =
          jsonData.map((json) => NoteModel.fromJson(json)).toList();
      sendPort.send(IsolateMessage(MessageType.CacheLoad, parsedNotes));
    } catch (e) {
      sendPort.send(IsolateMessage(MessageType.Error, e.toString()));
    }
  }

  static void _processNewNotes(String data, SendPort sendPort) {
    try {
      final List<dynamic> jsonData = json.decode(data);
      final List<NoteModel> parsedNotes =
          jsonData.map((json) => NoteModel.fromJson(json)).toList();
      sendPort.send(IsolateMessage(MessageType.NewNotes, parsedNotes));
    } catch (e) {
      sendPort.send(IsolateMessage(MessageType.Error, e.toString()));
    }
  }

  Request _createRequest(Filter filter) => Request(generateUUID(), [filter]);

  void _startRealTimeSubscription(List<String> targetNpubs) {
    final filter = Filter(
      authors: targetNpubs,
      kinds: [1, 6, 7],
      since: (notes.isNotEmpty)
          ? (notes.first.timestamp.millisecondsSinceEpoch ~/ 1000)
          : null,
    );
    final request = Request(generateUUID(), [filter]);
    _safeBroadcast(request.serialize());
    print('[DataService] Started real-time subscription for new events.');
  }

  Future<void> _fetchUserData() async {
    List<String> targetNpubs;
    if (dataType == DataType.Feed) {
      final following = await getFollowingList(npub);
      following.add(npub);
      targetNpubs = following.toSet().toList();
    } else {
      targetNpubs = [npub];
    }

    if (_isClosed) return;

    await _socketManager.connectRelays(targetNpubs,
        onEvent: (event, relayUrl) => _handleEvent(event, targetNpubs),
        onDisconnected: (relayUrl) =>
            _socketManager.reconnectRelay(relayUrl, targetNpubs));

    await fetchNotes(targetNpubs, initialLoad: true);

    await Future.wait([
      loadReactionsFromCache(),
      loadRepliesFromCache(),
      loadRepostsFromCache(),
    ]);

    await _subscribeToAllReactions();

    _startRealTimeSubscription(targetNpubs);
    await getCachedUserProfile(npub);
  }

  Future<void> initializeConnections() async {
    if (!_isInitialized) return;
    List<String> targetNpubs;
    if (dataType == DataType.Feed) {
      final following = await getFollowingList(npub);
      following.add(npub);
      targetNpubs = following.toSet().toList();
    } else {
      targetNpubs = [npub];
    }

    if (_isClosed) return;

    await _socketManager.connectRelays(targetNpubs,
        onEvent: (event, relayUrl) => _handleEvent(event, targetNpubs),
        onDisconnected: (relayUrl) =>
            _socketManager.reconnectRelay(relayUrl, targetNpubs));

    await fetchNotes(targetNpubs, initialLoad: true);

    await Future.wait([
      loadReactionsFromCache(),
      loadRepliesFromCache(),
      loadRepostsFromCache(),
    ]);

    await _subscribeToAllReactions();
    _startRealTimeSubscription(targetNpubs);
  }

  Future<void> _broadcastRequest(Request request) async =>
      await _safeBroadcast(request.serialize());

  Future<void> _safeBroadcast(String message) async {
    try {
      await _socketManager.broadcast(message);
    } catch (e) {}
  }

  Future<void> fetchNotes(List<String> targetNpubs,
      {bool initialLoad = false}) async {
    if (_isClosed) return;

    DateTime? sinceTimestamp;
    if (!initialLoad && notes.isNotEmpty) {
      sinceTimestamp = notes.first.timestamp;
    }

    final filter = Filter(
      authors: targetNpubs,
      kinds: [1, 6],
      limit: currentLimit,
      since: sinceTimestamp != null
          ? sinceTimestamp.millisecondsSinceEpoch ~/ 1000
          : null,
    );

    await _broadcastRequest(_createRequest(filter));
    print('[DataService] Fetched notes with filter: $filter');
  }

  Future<void> _fetchProfilesBatch(List<String> npubs) async {
    if (_isClosed) return;

    final uniqueNpubs =
        npubs.toSet().difference(profileCache.keys.toSet()).toList();
    if (uniqueNpubs.isEmpty) return;

    final filter =
        Filter(authors: uniqueNpubs, kinds: [0], limit: uniqueNpubs.length);
    await _broadcastRequest(_createRequest(filter));
    print(
        '[DataService] Sent profile fetch request for ${uniqueNpubs.length} authors.');
  }

  Future<void> _handleEvent(dynamic event, List<String> targetNpubs) async {
    if (_isClosed) return;
    try {
      final decodedEvent = jsonDecode(event);
      if (decodedEvent[0] == 'EVENT') {
        final Map<String, dynamic> eventData =
            decodedEvent[2] as Map<String, dynamic>;
        final kind = eventData['kind'] as int;
        if (kind == 0) {
          await _handleProfileEvent(eventData);
        } else if (kind == 7) {
          await _handleReactionEvent(eventData);
        } else if (kind == 1) {
          await _processNoteEvent(eventData, targetNpubs);
        } else if (kind == 6) {
          await _handleRepostEvent(eventData);
          await _processNoteEvent(eventData, targetNpubs);
        }
      }
    } catch (e) {
      print('[DataService ERROR] Error handling event: $e');
    }
  }

  String? _extractParentNoteId(List<dynamic> tags) {
    for (var tag in tags) {
      if (tag is List && tag.isNotEmpty && tag[0] == 'e') {
        return tag[1] as String?;
      }
    }
    return null;
  }

  Future<void> _processNoteEvent(
      Map<String, dynamic> eventData, List<String> targetNpubs) async {
    int kind = eventData['kind'] as int;
    final author = eventData['pubkey'] as String;
    bool isRepost = kind == 6;
    Map<String, dynamic>? originalEventData;
    DateTime? repostTimestamp;
    String rawWsData = jsonEncode(eventData);

    if (isRepost) {
      repostTimestamp =
          DateTime.fromMillisecondsSinceEpoch(eventData['created_at'] * 1000);
      final contentRaw = eventData['content'];
      if (contentRaw is String && contentRaw.isNotEmpty) {
        try {
          originalEventData = jsonDecode(contentRaw) as Map<String, dynamic>;
        } catch (e) {
          originalEventData = null;
        }
      }
      if (originalEventData == null) {
        String? originalNoteId;
        for (var tag in eventData['tags']) {
          if (tag is List && tag.length >= 2 && tag[0] == 'e') {
            originalNoteId = tag[1] as String;
            break;
          }
        }
        if (originalNoteId != null) {
          originalEventData = await _fetchNoteById(originalNoteId);
        }
      }
      if (originalEventData == null) return;
      rawWsData = jsonEncode(originalEventData);
      eventData = originalEventData;
    }

    final noteId = eventData['id'] as String?;
    if (noteId == null) {
      print('[DataService] Note ID is null.');
      return;
    }

    final noteAuthor = eventData['pubkey'] as String;
    final noteContentRaw = eventData['content'];
    String noteContent =
        noteContentRaw is String ? noteContentRaw : jsonEncode(noteContentRaw);
    final tags = eventData['tags'] as List<dynamic>;
    final parentNoteId = _extractParentNoteId(tags);

    final timestamp = DateTime.fromMillisecondsSinceEpoch(
        (eventData['created_at'] as int) * 1000);

    final newNote = NoteModel(
      id: noteId,
      content: noteContent,
      author: noteAuthor,
      timestamp: timestamp,
      isRepost: isRepost,
      repostedBy: isRepost ? author : null,
      repostTimestamp: repostTimestamp,
      rawWs: rawWsData,
    );

    String uniqueKey = _noteUniqueKey(newNote);

    if (parentNoteId == null) {
      if (dataType == DataType.Feed &&
          targetNpubs.isNotEmpty &&
          !isRepost &&
          !targetNpubs.contains(noteAuthor)) {
        return;
      }
    }

    if (parentNoteId != null) {
      await _handleReplyEvent(eventData, parentNoteId);
    } else {
      final noteInstance = newNote.copyWith();

      if (!noteKeys.contains(uniqueKey) && noteContent.trim().isNotEmpty) {
        notes.add(noteInstance);
        noteKeys.add(uniqueKey);
        if (notesBox != null && notesBox!.isOpen) {
          await notesBox!.put(uniqueKey, noteInstance);
        }
      }

      _sortNotes();
      onNewNote?.call(noteInstance);
      print('[DataService] New note added and saved to cache: $uniqueKey');

      List<String> newNoteKeys = [uniqueKey];
      await Future.wait([
        fetchReactionsForNotes(newNoteKeys),
        fetchRepliesForNotes(newNoteKeys),
        fetchRepostsForNotes(newNoteKeys)
      ]);
      await _updateReactionSubscription();
    }

    int currentRepostCount = repostsMap[noteId]?.length ?? 0;
    int currentReactionCount = reactionsMap[noteId]?.length ?? 0;
    int currentReplyCount = repliesMap[noteId]?.length ?? 0;
    _updateNoteCounts(noteId,
        repostCount: currentRepostCount,
        reactionCount: currentReactionCount,
        replyCount: currentReplyCount);
  }

  void _sortNotes() => notes.sort((a, b) => b.timestamp.compareTo(a.timestamp));

  Future<void> _handleReactionEvent(Map<String, dynamic> eventData) async {
    if (_isClosed) return;
    try {
      String? targetNoteId;
      for (var tag in eventData['tags']) {
        if (tag is List && tag.length >= 2 && tag[0] == 'e') {
          targetNoteId = tag[1] as String;
          break;
        }
      }
      if (targetNoteId == null) return;

      final reaction = ReactionModel.fromEvent(eventData);
      reactionsMap.putIfAbsent(targetNoteId, () => []);

      if (!reactionsMap[targetNoteId]!.any((r) => r.id == reaction.id)) {
        reactionsMap[targetNoteId]!.add(reaction);
        onReactionsUpdated?.call(targetNoteId, reactionsMap[targetNoteId]!);
        await reactionsBox?.put(reaction.id, reaction);
      }
    } catch (e) {
      print('[DataService ERROR] Error handling reaction event: $e');
    }
  }

  Future<void> _handleReplyEvent(
      Map<String, dynamic> eventData, String parentNoteId) async {
    if (_isClosed) return;
    try {
      final reply = ReplyModel.fromEvent(eventData);
      repliesMap.putIfAbsent(parentNoteId, () => []);

      if (!repliesMap[parentNoteId]!.any((r) => r.id == reply.id)) {
        repliesMap[parentNoteId]!.add(reply);
        onRepliesUpdated?.call(parentNoteId, repliesMap[parentNoteId]!);

        int count = repliesMap[parentNoteId]!.length;
        onReplyCountUpdated?.call(parentNoteId, count);
        _updateNoteCounts(parentNoteId, replyCount: count);

        await repliesBox?.put(reply.id, reply);
      }
    } catch (e) {
      print('[DataService ERROR] Error handling reply event: $e');
    }
  }

  Future<void> _handleRepostEvent(Map<String, dynamic> eventData) async {
    if (_isClosed) return;
    try {
      String? originalNoteId;
      for (var tag in eventData['tags']) {
        if (tag is List && tag.isNotEmpty && tag[0] == 'e') {
          originalNoteId = tag[1] as String?;
          break;
        }
      }
      if (originalNoteId == null) return;

      final repost = RepostModel.fromEvent(eventData, originalNoteId);
      repostsMap.putIfAbsent(originalNoteId, () => []);

      if (!repostsMap[originalNoteId]!.any((r) => r.id == repost.id)) {
        repostsMap[originalNoteId]!.add(repost);
        onRepostsUpdated?.call(originalNoteId, repostsMap[originalNoteId]!);

        int count = repostsMap[originalNoteId]!.length;
        onRepostCountUpdated?.call(originalNoteId, count);
        _updateNoteCounts(originalNoteId, repostCount: count);

        await repostsBox?.put(repost.id, repost);
      }
    } catch (e) {
      print('[DataService ERROR] Error handling repost event: $e');
    }
  }

  void _updateNoteCounts(String noteId,
      {int? reactionCount, int? replyCount, int? repostCount}) {
    final index = notes.indexWhere((note) => note.id == noteId);
    if (index != -1) {
      final note = notes[index];
      note.save();
      final key = _noteUniqueKey(note);
      notesBox?.put(key, note);
    }
  }

  Future<void> _handleProfileEvent(Map<String, dynamic> eventData) async {
    if (_isClosed) return;
    try {
      final author = eventData['pubkey'] as String;
      final createdAt =
          DateTime.fromMillisecondsSinceEpoch(eventData['created_at'] * 1000);
      final contentRaw = eventData['content'];

      Map<String, dynamic> profileContent;
      if (contentRaw is String && contentRaw.isNotEmpty) {
        try {
          profileContent = jsonDecode(contentRaw) as Map<String, dynamic>;
        } catch (e) {
          profileContent = {};
        }
      } else {
        profileContent = {};
      }

      final userName = profileContent['name'] as String? ?? 'Anonymous';
      final profileImage = profileContent['picture'] as String? ?? '';
      final about = profileContent['about'] as String? ?? '';
      final nip05 = profileContent['nip05'] as String? ?? '';
      final banner = profileContent['banner'] as String? ?? '';
      final lud16 = profileContent['lud16'] as String? ?? '';
      final website = profileContent['website'] as String? ?? '';

      if (profileCache.containsKey(author)) {
        final cachedProfile = profileCache[author]!;
        if (createdAt.isBefore(cachedProfile.fetchedAt)) {
          print(
              '[DataService] Profile event ignored for $author: older data received.');
          return;
        }
      }

      profileCache[author] = CachedProfile({
        'name': userName,
        'profileImage': profileImage,
        'about': about,
        'nip05': nip05,
        'banner': banner,
        'lud16': lud16,
        'website': website,
      }, createdAt);

      if (usersBox != null && usersBox!.isOpen) {
        final userModel = UserModel(
          npub: author,
          name: userName,
          about: about,
          nip05: nip05,
          banner: banner,
          profileImage: profileImage,
          lud16: lud16,
          website: website,
          updatedAt: createdAt,
        );
        await usersBox!.put(author, userModel);
      }

      if (_pendingProfileRequests.containsKey(author)) {
        _pendingProfileRequests[author]?.complete(profileCache[author]!.data);
        _pendingProfileRequests.remove(author);
      }
    } catch (e) {
      print('[DataService ERROR] Error handling profile event: $e');
    }
  }

  Future<Map<String, String>> getCachedUserProfile(String npub) async {
    if (_isClosed) {
      return {
        'name': 'Anonymous',
        'profileImage': '',
        'about': '',
        'nip05': '',
        'banner': '',
        'lud16': '',
        'website': ''
      };
    }

    final now = DateTime.now();
    if (profileCache.containsKey(npub)) {
      final cached = profileCache[npub]!;
      if (now.difference(cached.fetchedAt) < profileCacheTTL) {
        return cached.data;
      } else {
        profileCache.remove(npub);
      }
    }

    if (usersBox != null && usersBox!.isOpen) {
      final user = usersBox!.get(npub);
      if (user != null) {
        final data = {
          'name': user.name,
          'profileImage': user.profileImage,
          'about': user.about,
          'nip05': user.nip05,
          'banner': user.banner,
          'lud16': user.lud16,
          'website': user.website,
        };
        profileCache[npub] = CachedProfile(data, user.updatedAt);
        return data;
      }
    }

    if (_pendingProfileRequests.containsKey(npub)) {
      return await _pendingProfileRequests[npub]!.future;
    }

    final completer = Completer<Map<String, String>>();
    _pendingProfileRequests[npub] = completer;

    String subscriptionId = generateUUID();
    _profileSubscriptionIds[subscriptionId] = npub;

    final request =
        _createRequest(Filter(authors: [npub], kinds: [0], limit: 1));
    await _broadcastRequest(request);

    try {
      return await completer.future.timeout(const Duration(seconds: 1),
          onTimeout: () => {
                'name': 'Anonymous',
                'profileImage': '',
                'about': '',
                'nip05': '',
                'banner': '',
                'lud16': '',
                'website': ''
              });
    } catch (e) {
      return {
        'name': 'Anonymous',
        'profileImage': '',
        'about': '',
        'nip05': '',
        'banner': '',
        'lud16': '',
        'website': ''
      };
    }
  }

  Future<List<String>> getFollowingList(String npub) async {
    List<String> following = [];
    final limitedRelays = _socketManager.relayUrls.take(3).toList();

    await Future.wait(limitedRelays.map((relayUrl) async {
      try {
        final ws = await WebSocket.connect(relayUrl)
            .timeout(const Duration(seconds: 1));
        if (_isClosed) {
          await ws.close();
          return;
        }
        final request =
            _createRequest(Filter(authors: [npub], kinds: [3], limit: 1000));
        final completer = Completer<void>();

        ws.listen((event) {
          final decoded = jsonDecode(event);
          if (decoded[0] == 'EVENT') {
            for (var tag in decoded[2]['tags']) {
              if (tag is List && tag.isNotEmpty && tag[0] == 'p') {
                following.add(tag[1] as String);
              }
            }
            completer.complete();
          }
        }, onDone: () {
          if (!completer.isCompleted) completer.complete();
        }, onError: (error) {
          if (!completer.isCompleted) completer.complete();
        });

        ws.add(request.serialize());
        await completer.future.timeout(const Duration(seconds: 1),
            onTimeout: () async {
          await ws.close();
        });
        await ws.close();
      } catch (e) {}
    }));

    following = following.toSet().toList();
    return following;
  }

  Future<void> fetchOlderNotes(
      List<String> targetNpubs, Function(NoteModel) onOlderNote) async {
    if (_isClosed || notes.isEmpty) return;
    final lastNote = notes.last;
    final filter = Filter(
      authors: targetNpubs,
      kinds: [1, 6],
      limit: currentLimit,
      until: lastNote.timestamp.millisecondsSinceEpoch ~/ 1000,
    );
    final request = _createRequest(filter);
    await _broadcastRequest(request);
  }

  Future<void> _subscribeToAllReactions() async {
    if (_isClosed) return;
    String subscriptionId = generateUUID();
    List<String> allNoteKeys =
        notes.map((note) => _noteUniqueKey(note)).toList();
    if (allNoteKeys.isEmpty) return;

    final filter = Filter(kinds: [7], e: allNoteKeys, limit: 1000);
    final request = Request(subscriptionId, [filter]);
    await _broadcastRequest(request);
  }

  Future<void> _updateReactionSubscription() async =>
      await _subscribeToAllReactions();

  void _startCacheCleanup() {
    _cacheCleanupTimer?.cancel();
    _cacheCleanupTimer = Timer.periodic(cacheCleanupInterval, (timer) async {
      if (_isClosed) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      profileCache.removeWhere(
          (key, cached) => now.difference(cached.fetchedAt) > profileCacheTTL);

      reactionsMap.forEach((noteId, reactions) {
        reactions.removeWhere(
            (reaction) => now.difference(reaction.fetchedAt) > profileCacheTTL);
      });

      repliesMap.forEach((noteId, replies) {
        replies.removeWhere(
            (reply) => now.difference(reply.fetchedAt) > profileCacheTTL);
      });

      await Future.wait([
        if (reactionsBox != null && reactionsBox!.isOpen)
          reactionsBox!.deleteAll(reactionsBox!.keys.where((key) {
            final reaction = reactionsBox!.get(key);
            return reaction != null &&
                now.difference(reaction.fetchedAt) > profileCacheTTL;
          })),
        if (repliesBox != null && repliesBox!.isOpen)
          repliesBox!.deleteAll(repliesBox!.keys.where((key) {
            final reply = repliesBox!.get(key);
            return reply != null &&
                now.difference(reply.fetchedAt) > profileCacheTTL;
          })),
      ]);

      print('[DataService] Performed cache cleanup.');
    });
    print('[DataService] Started cache cleanup timer.');
  }

  Future<void> shareNote(String noteContent) async {
    if (_isClosed) return;
    try {
      final privateKey = await _secureStorage.read(key: 'privateKey');
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('Private key not found.');
      }

      final event = Event.from(
          kind: 1, tags: [], content: noteContent, privkey: privateKey);
      final serializedEvent = event.serialize();
      await _socketManager.broadcast(serializedEvent);
      print('[DataService] Note shared successfully.');
    } catch (e) {
      print('[DataService ERROR] Error sharing note: $e');
      throw e;
    }
  }

  Future<void> sendReaction(String targetNoteId, String reactionContent) async {
    if (_isClosed) return;
    try {
      final privateKey = await _secureStorage.read(key: 'privateKey');
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('Private key not found.');
      }

      final event = Event.from(
          kind: 7,
          tags: [
            ['e', targetNoteId]
          ],
          content: reactionContent,
          privkey: privateKey);
      final serializedEvent = event.serialize();
      await _socketManager.broadcast(serializedEvent);
      print('[DataService] Reaction event sent to WebSocket successfully.');
    } catch (e) {
      print('[DataService ERROR] Error sending reaction: $e');
      throw e;
    }
  }

  Future<void> sendReply(String parentNoteId, String replyContent) async {
    if (_isClosed) return;
    try {
      final privateKey = await _secureStorage.read(key: 'privateKey');
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('Private key not found.');
      }
      String noteAuthor = notes
          .firstWhere((note) => note.id == parentNoteId,
              orElse: () => throw Exception('Note not found for reply.'))
          .author;

      final event = Event.from(
          kind: 1,
          tags: [
            ['e', parentNoteId, '', 'root'],
            ['p', noteAuthor]
          ],
          content: replyContent,
          privkey: privateKey);
      final serializedEvent = event.serialize();
      await _socketManager.broadcast(serializedEvent);
      print('[DataService] Reply event sent to WebSocket successfully.');
    } catch (e) {
      print('[DataService ERROR] Error sending reply: $e');
      throw e;
    }
  }

  Future<void> saveNotesToCache() async {
    if (notesBox != null && notesBox!.isOpen) {
      try {
        final Map<String, NoteModel> notesMap = {
          for (var note in notes) _noteUniqueKey(note): note
        };
        await notesBox!.putAll(notesMap);
        print('[DataService] Notes saved to cache successfully.');
      } catch (e) {
        print('[DataService ERROR] Error saving notes to cache: $e');
      }
    }
  }

  Future<void> loadNotesFromCache(Function(List<NoteModel>) onLoad) async {
    if (notesBox == null || !notesBox!.isOpen) return;
    try {
      final allNotes = notesBox!.values.cast<NoteModel>().toList();
      if (allNotes.isEmpty) return;

      for (var note in allNotes) {
        final key = _noteUniqueKey(note);
        if (!noteKeys.contains(key)) {
          notes.add(note);
          noteKeys.add(key);
        }
      }

      onLoad(allNotes);
      print('[DataService] Cache loaded with ${allNotes.length} notes.');

      List<String> cachedNoteKeys =
          allNotes.map((note) => _noteUniqueKey(note)).toList();

      await Future.wait([
        fetchReactionsForNotes(cachedNoteKeys),
        fetchRepliesForNotes(cachedNoteKeys),
        fetchRepostsForNotes(cachedNoteKeys)
      ]);
    } catch (e) {
      print('[DataService ERROR] Error loading notes from cache: $e');
    }
    await _fetchProfilesForAllData();
  }

  Future<void> loadReactionsFromCache() async {
    if (reactionsBox == null || !reactionsBox!.isOpen) return;
    try {
      final allReactions = reactionsBox!.values.cast<ReactionModel>().toList();
      if (allReactions.isEmpty) return;

      for (var reaction in allReactions) {
        reactionsMap.putIfAbsent(reaction.targetNoteId, () => []);
        if (!reactionsMap[reaction.targetNoteId]!
            .any((r) => r.id == reaction.id)) {
          reactionsMap[reaction.targetNoteId]!.add(reaction);
          onReactionsUpdated?.call(
              reaction.targetNoteId, reactionsMap[reaction.targetNoteId]!);
        }
      }
      print(
          '[DataService] Reactions cache loaded with ${allReactions.length} reactions.');
    } catch (e) {
      print('[DataService ERROR] Error loading reactions from cache: $e');
    }
  }

  Future<void> loadRepliesFromCache() async {
    if (repliesBox == null || !repliesBox!.isOpen) return;
    try {
      final allReplies = repliesBox!.values.cast<ReplyModel>().toList();
      if (allReplies.isEmpty) return;

      for (var reply in allReplies) {
        repliesMap.putIfAbsent(reply.parentNoteId, () => []);
        if (!repliesMap[reply.parentNoteId]!.any((r) => r.id == reply.id)) {
          repliesMap[reply.parentNoteId]!.add(reply);
        }
      }
      print(
          '[DataService] Replies cache loaded with ${allReplies.length} replies.');
    } catch (e) {
      print('[DataService ERROR] Error loading replies from cache: $e');
    }
  }

  Future<void> loadRepostsFromCache() async {
    if (repostsBox == null || !repostsBox!.isOpen) return;
    try {
      final allReposts = repostsBox!.values.cast<RepostModel>().toList();
      if (allReposts.isEmpty) return;

      for (var repost in allReposts) {
        repostsMap.putIfAbsent(repost.originalNoteId, () => []);
        if (!repostsMap[repost.originalNoteId]!.any((r) => r.id == repost.id)) {
          repostsMap[repost.originalNoteId]!.add(repost);
          onRepostsUpdated?.call(
              repost.originalNoteId, repostsMap[repost.originalNoteId]!);
        }
      }
      print(
          '[DataService] Reposts cache loaded with ${allReposts.length} reposts.');
    } catch (e) {
      print('[DataService ERROR] Error loading reposts from cache: $e');
    }
  }

  Future<void> _handleNewNotes(dynamic data) async {
    if (data is List<NoteModel> && data.isNotEmpty) {
      for (var note in data) {
        final key = _noteUniqueKey(note);
        if (!noteKeys.contains(key)) {
          notes.add(note);
          noteKeys.add(key);
          await notesBox!.put(key, note);
        }
      }
      _sortNotes();
      onNewNote?.call(data.last);
      print('[DataService] Handled new notes: ${data.length} notes added.');

      List<String> newNoteKeys =
          data.map((note) => _noteUniqueKey(note)).toList();
      await Future.wait([
        fetchReactionsForNotes(newNoteKeys),
        fetchRepliesForNotes(newNoteKeys),
        fetchRepostsForNotes(newNoteKeys)
      ]);
      await _updateReactionSubscription();
    }
  }

  Future<void> fetchReactionsForNotes(List<String> noteKeysToFetch) async {
    if (_isClosed) return;
    final request = Request(generateUUID(), [
      Filter(kinds: [7], e: noteKeysToFetch, limit: 1000)
    ]);
    await _broadcastRequest(request);
  }

  Future<void> fetchRepliesForNotes(List<String> parentNoteKeys) async {
    if (_isClosed) return;
    final request = Request(generateUUID(), [
      Filter(kinds: [1], e: parentNoteKeys, limit: 1000)
    ]);
    await _broadcastRequest(request);
  }

  Future<void> fetchRepostsForNotes(List<String> noteKeysToFetch) async {
    if (_isClosed) return;
    final request = Request(generateUUID(), [
      Filter(kinds: [6], e: noteKeysToFetch, limit: 1000)
    ]);
    await _broadcastRequest(request);
  }

  void _handleCacheLoad(dynamic data) {
    if (data is List<NoteModel>) {
      if (_onCacheLoad != null) {
        _onCacheLoad!(data);
        _onCacheLoad = null;
      }
    }
  }

  Future<void> _fetchProfilesForAllData() async {
    if (_isClosed) return;
    Set<String> allAuthors = notes.map((note) => note.author).toSet();

    for (var replies in repliesMap.values) {
      allAuthors.addAll(replies.map((reply) => reply.author));
    }
    for (var reactions in reactionsMap.values) {
      allAuthors.addAll(reactions.map((reaction) => reaction.author));
    }

    await _fetchProfilesBatch(allAuthors.toList());
  }

  Future<Map<String, dynamic>?> _fetchNoteById(String noteId) async {
    if (_isClosed) return null;
    final completer = Completer<Map<String, dynamic>?>();
    String subscriptionId = generateUUID();
    final request = Request(subscriptionId, [
      Filter(ids: [noteId], limit: 1)
    ]);
    StreamSubscription? subscription;

    await Future.wait(_socketManager.activeSockets.map((ws) async {
      if (ws.readyState == WebSocket.open) {
        subscription = ws.listen((event) {
          final decoded = jsonDecode(event);
          if (decoded[0] == 'EVENT' && decoded[1] == subscriptionId) {
            completer.complete(decoded[2] as Map<String, dynamic>);
            subscription?.cancel();
          } else if (decoded[0] == 'EOSE' && decoded[1] == subscriptionId) {
            if (!completer.isCompleted) completer.complete(null);
            subscription?.cancel();
          }
        }, onError: (error) {
          if (!completer.isCompleted) completer.complete(null);
          subscription?.cancel();
        });

        ws.add(request.serialize());
      }
    }));

    return completer.future.timeout(const Duration(seconds: 1), onTimeout: () {
      return null;
    });
  }

  String generateUUID() => _uuid.v4().replaceAll('-', '');

  Future<void> closeConnections() async {
    if (_isClosed) return;
    _isClosed = true;

    _checkNewNotesTimer?.cancel();
    _cacheCleanupTimer?.cancel();

    try {
      if (_sendPortReadyCompleter.isCompleted) {
        _sendPort.send(IsolateMessage(MessageType.Close, 'close'));
      }
    } catch (e) {}

    _isolate.kill(priority: Isolate.immediate);
    _receivePort.close();
    await _socketManager.closeConnections();

    print('[DataService] All connections closed. Hive boxes remain open.');
  }
}
