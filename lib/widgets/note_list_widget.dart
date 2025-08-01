import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../theme/theme_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:qiqstr/models/note_model.dart';
import 'package:qiqstr/services/data_service.dart';
import 'package:qiqstr/widgets/note_widget.dart';

enum NoteListFilterType {
  latest,
  popular,
  media,
}

class NoteListWidget extends StatefulWidget {
  final String npub;
  final DataType dataType;
  final NoteListFilterType filterType;

  const NoteListWidget({
    super.key,
    required this.npub,
    required this.dataType,
    this.filterType = NoteListFilterType.latest,
  });

  @override
  State<NoteListWidget> createState() => _NoteListWidgetState();
}

class _NoteListWidgetState extends State<NoteListWidget> {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final ScrollController _scrollController = ScrollController();
  late DataService _dataService;

  String? _currentUserNpub;
  bool _isInitializing = true;
  bool _isLoadingMore = false;

  List<NoteModel> _filteredNotes = [];
  
  static const int _itemsPerPage = 50;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }
  
  @override
  void didUpdateWidget(NoteListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filterType != widget.filterType) {
      _updateFilteredNotes(_dataService.notesNotifier.value);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _dataService.notesNotifier.removeListener(_onNotesChanged);
    _dataService.closeConnections();
    super.dispose();
  }

  void _onNotesChanged() {
    if (mounted) {
      _updateFilteredNotes(_dataService.notesNotifier.value);
    }
  }

  Future<void> _initialize() async {
    _currentUserNpub = await _secureStorage.read(key: 'npub');
    if (!mounted) return;

    _dataService = _createDataService();
    _dataService.notesNotifier.addListener(_onNotesChanged);
    await _dataService.initialize();
    _dataService.initializeConnections();

    setState(() {
      _isInitializing = false;
    });
  }

  DataService _createDataService() {
    return DataService(
      npub: widget.npub,
      dataType: widget.dataType,
      onNewNote: (_) {},
      onReactionsUpdated: (_, __) {},
      onRepliesUpdated: (_, __) {},
      onRepostsUpdated: (_, __) {},
      onReactionCountUpdated: (_, __) {},
      onReplyCountUpdated: (_, __) {},
      onRepostCountUpdated: (_, __) {},
    );
  }
  
  void _onScroll() {
    if (!_isLoadingMore && _scrollController.position.pixels >= _scrollController.position.maxScrollExtent * 0.9) {
      final allAvailableNotes = _filteredNotes.length;
      final currentlyVisibleNotes = (_currentPage + 1) * _itemsPerPage;

      if (currentlyVisibleNotes >= allAvailableNotes) {
        _loadMoreItemsFromNetwork();
      } else {
        _showMoreFromCache();
      }
    }
  }

  void _loadMoreItemsFromNetwork() {
    if (_isLoadingMore) return;

    setState(() => _isLoadingMore = true);

    _dataService.loadMoreNotes().whenComplete(() {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    });
  }

  void _showMoreFromCache() {
    if (_isLoadingMore) return;
    setState(() {
      _currentPage++;
    });
  }

  Future<void> _updateFilteredNotes(List<NoteModel> notes) async {
    List<NoteModel> filtered;
    switch (widget.filterType) {
      case NoteListFilterType.popular:
        filtered = await compute(_filterAndSortPopular, notes);
        break;
      case NoteListFilterType.media:
        filtered = notes.where((n) => n.hasMedia && (!n.isReply || n.isRepost)).toList();
        break;
      case NoteListFilterType.latest:
        filtered = notes.where((n) => !n.isReply || n.isRepost).toList();
        break;
    }
    
    if (mounted) {
      setState(() {
        _filteredNotes = filtered;
        _currentPage = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing || _currentUserNpub == null) {
      return const SliverToBoxAdapter(
        child: Center(child: Padding(padding: EdgeInsets.all(40.0), child: Text("Loading..."))),
      );
    }

    if (_filteredNotes.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(child: Padding(padding: EdgeInsets.all(24.0), child: Text('No notes found.'))),
      );
    }

    final totalItems = _filteredNotes.length;
    final visibleItems = (_currentPage + 1) * _itemsPerPage;
    final itemsToShow = visibleItems > totalItems ? totalItems : visibleItems;

    return SliverList.separated(
      itemCount: itemsToShow + (_isLoadingMore ? 1 : 0),
      separatorBuilder: (context, index) => Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        height: 1,
        width: double.infinity,
        color: context.colors.surfaceTransparent,
      ),
      itemBuilder: (context, index) {
        if (index >= itemsToShow) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }

        final note = _filteredNotes[index];
        return NoteWidget(
          key: ValueKey(note.id),
          note: note,
          reactionCount: note.reactionCount,
          replyCount: note.replyCount,
          repostCount: note.repostCount,
          dataService: _dataService,
          currentUserNpub: _currentUserNpub!,
          notesNotifier: _dataService.notesNotifier,
          profiles: _dataService.profilesNotifier.value,
          isSmallView: true,
        );
      },
    );
  }
}

List<NoteModel> _filterAndSortPopular(List<NoteModel> notes) {
  final cutoffTime = DateTime.now().subtract(const Duration(hours: 24));
  final filtered = notes.where((n) => n.timestamp.isAfter(cutoffTime) && (!n.isReply || n.isRepost)).toList();

  int calculateEngagementScore(NoteModel note) {
    return note.reactionCount + note.replyCount + note.repostCount + (note.zapAmount ~/ 1000);
  }

  filtered.sort((a, b) => calculateEngagementScore(b).compareTo(calculateEngagementScore(a)));
  return filtered;
}
