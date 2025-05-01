import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qiqstr/models/user_model.dart';
import 'package:qiqstr/screens/send_reply.dart';
import 'package:qiqstr/widgets/link_preview_widget.dart';
import 'package:qiqstr/widgets/media_preview_widget.dart';
import '../models/note_model.dart';
import '../services/qiqstr_service.dart';
import 'quote_widget.dart';

class NoteWidget extends StatefulWidget {
  final NoteModel note;
  final int reactionCount;
  final int replyCount;
  final int repostCount;
  final DataService dataService;
  final String currentUserNpub;
  final ValueNotifier<List<NoteModel>> notesNotifier;

  const NoteWidget(
      {super.key,
      required this.note,
      required this.reactionCount,
      required this.replyCount,
      required this.repostCount,
      required this.dataService,
      required this.currentUserNpub,
      required this.notesNotifier});

  @override
  _NoteWidgetState createState() => _NoteWidgetState();
}

class _NoteWidgetState extends State<NoteWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool _isReactionGlowing = false;
  bool _isReplyGlowing = false;
  bool _isRepostGlowing = false;
  double _reactionScale = 1.0;
  double _replyScale = 1.0;
  double _repostScale = 1.0;
  bool _isZapGlowing = false;
  double _zapScale = 1.0;

  String _formatTimestamp(DateTime timestamp) {
    final d = DateTime.now().difference(timestamp);
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    if (d.inDays < 30) return '${(d.inDays / 7).floor()}w';
    if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
    return '${(d.inDays / 365).floor()}y';
  }

  void _navigateToMentionProfile(String id) {
    widget.dataService.openUserProfile(context, id);
  }

  Widget _buildContentText(Map<String, dynamic> parsed) {
    final parts = parsed['textParts'] as List<Map<String, dynamic>>;
    final mentionIds = parts
        .where((p) => p['type'] == 'mention')
        .map((p) => p['id'] as String)
        .toList();

    return FutureBuilder<Map<String, String>>(
      future: widget.dataService.resolveMentions(mentionIds),
      builder: (context, snapshot) {
        final mentions = snapshot.data ?? {};
        List<InlineSpan> spans = [];

        for (var p in parts) {
          if (p['type'] == 'text') {
            final text = p['text'] as String;
            final regex = RegExp(r'(https?:\/\/[^\s]+)');
            final matches = regex.allMatches(text);
            int lastMatchEnd = 0;

            for (final match in matches) {
              if (match.start > lastMatchEnd) {
                spans.add(TextSpan(
                  text: text.substring(lastMatchEnd, match.start),
                  style: TextStyle(
                    fontSize: 15.5,
                    color: Colors.white,
                  ),
                ));
              }

              final url = text.substring(match.start, match.end);
              spans.add(TextSpan(
                text: url,
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontStyle: FontStyle.italic,
                  fontSize: 15.5,
                ),
                recognizer: TapGestureRecognizer()
                  ..onTap = () => _onOpen(LinkableElement(url, url)),
              ));
              lastMatchEnd = match.end;
            }

            if (lastMatchEnd < text.length) {
              spans.add(TextSpan(
                text: text.substring(lastMatchEnd),
                style: TextStyle(
                  fontSize: 15.5,
                  color: Colors.white,
                ),
              ));
            }
          } else if (p['type'] == 'mention') {
            final username =
                mentions[p['id']] ?? '${p['id'].substring(0, 8)}...';
            spans.add(
              TextSpan(
                text: '@$username',
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                  fontStyle: FontStyle.italic,
                ),
                recognizer: TapGestureRecognizer()
                  ..onTap = () => _navigateToMentionProfile(p['id']),
              ),
            );
          }
        }

        return RichText(text: TextSpan(children: spans));
      },
    );
  }

  void _animateZapButton() {
    setState(() {
      _zapScale = 1.2;
      _isZapGlowing = true;
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _zapScale = 1.0;
          _isZapGlowing = false;
        });
      }
    });
  }

  void _animateReactionButton() {
    setState(() {
      _reactionScale = 1.2;
      _isReactionGlowing = true;
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _reactionScale = 1.0;
          _isReactionGlowing = false;
        });
      }
    });
  }

  void _animateReplyButton() {
    setState(() {
      _replyScale = 1.2;
      _isReplyGlowing = true;
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _replyScale = 1.0;
          _isReplyGlowing = false;
        });
      }
    });
  }

  void _animateRepostButton() {
    setState(() {
      _repostScale = 1.2;
      _isRepostGlowing = true;
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _repostScale = 1.0;
          _isRepostGlowing = false;
        });
      }
    });
  }

  bool _hasReacted() {
    final r = widget.dataService.reactionsMap[widget.note.id] ?? [];
    return r.any((e) => e.author == widget.currentUserNpub);
  }

  bool _hasReplied() {
    final r = widget.dataService.repliesMap[widget.note.id] ?? [];
    return r.any((e) => e.author == widget.currentUserNpub);
  }

  bool _hasReposted() {
    final r = widget.dataService.repostsMap[widget.note.id] ?? [];
    return r.any((e) => e.repostedBy == widget.currentUserNpub);
  }

  void _handleZapTap() {
    _animateZapButton();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("I'm working on it"),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _handleReactionTap() async {
    _animateReactionButton();
    try {
      await widget.dataService.sendReaction(widget.note.id, '💜');
    } catch (_) {}
  }

  void _handleReplyTap() {
    _animateReplyButton();
    showDialog(
      context: context,
      builder: (_) => SendReplyDialog(
          dataService: widget.dataService, noteId: widget.note.id),
    );
  }

  void _handleRepostTap() async {
    _animateRepostButton();
    try {
      await widget.dataService.sendRepost(widget.note);
    } catch (_) {}
  }

  Future<void> _onOpen(LinkableElement link) async {
    final url = Uri.parse(link.url);
    if (await canLaunchUrl(url)) await launchUrl(url);
  }

  void _navigateToProfile(String npub) {
    widget.dataService.openUserProfile(context, npub);
  }

  Widget _buildRepostInfo(String npub, DateTime? ts) {
    return FutureBuilder<Map<String, String>>(
      future: widget.dataService.getCachedUserProfile(npub),
      builder: (_, snap) {
        String name = 'Unknown';
        if (snap.hasData) {
          name = snap.data!['name'] ?? 'Unknown';
        }
        return GestureDetector(
          onTap: () => _navigateToProfile(npub),
          child: Row(
            children: [
              const Icon(Icons.repeat, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'Reposted by $name',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (ts != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '• ${_formatTimestamp(ts)}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAction({
    required double scale,
    required String svg,
    required Color color,
    required int count,
    required VoidCallback onTap,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: scale),
      duration: const Duration(milliseconds: 300),
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: InkWell(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onTap: onTap,
        child: Row(
          children: [
            SvgPicture.asset(svg, width: 18, height: 18, color: color),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return ValueListenableBuilder<List<NoteModel>>(
      valueListenable: widget.notesNotifier,
      builder: (context, notes, _) {
        final updatedNote = notes.firstWhere(
          (n) => n.id == widget.note.id,
          orElse: () => widget.note,
        );

        widget.dataService.parseContentForNote(updatedNote);
        final parsed = updatedNote.parsedContent!;

        return GestureDetector(
          onDoubleTapDown: (_) => _handleReactionTap(),
          child: Container(
            color: Colors.black,
            padding: const EdgeInsets.only(bottom: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                if (updatedNote.isRepost && updatedNote.repostedBy != null) ...[
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: _buildRepostInfo(
                        updatedNote.repostedBy!, updatedNote.repostTimestamp),
                  ),
                  const SizedBox(height: 8),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FutureBuilder<Map<String, String>>(
                        future: widget.dataService
                            .getCachedUserProfile(updatedNote.author),
                        builder: (_, snap) {
                          String imgUrl = '';
                          if (snap.hasData) {
                            final user = UserModel.fromCachedProfile(
                                updatedNote.author, snap.data!);
                            imgUrl = user.profileImage;
                          }
                          return GestureDetector(
                            onTap: () => _navigateToProfile(updatedNote.author),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: CircleAvatar(
                                radius: 23,
                                backgroundImage: imgUrl.isNotEmpty
                                    ? CachedNetworkImageProvider(imgUrl)
                                    : null,
                                backgroundColor: imgUrl.isEmpty
                                    ? Colors.grey
                                    : Colors.transparent,
                                child: imgUrl.isEmpty
                                    ? const Icon(Icons.person,
                                        size: 20, color: Colors.white)
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FutureBuilder<Map<String, String>>(
                              future: widget.dataService
                                  .getCachedUserProfile(updatedNote.author),
                              builder: (_, snap) {
                                if (!snap.hasData) {
                                  return Container(
                                      height: 20,
                                      width: 100,
                                      color: Colors.grey[700]);
                                }
                                final user = UserModel.fromCachedProfile(
                                    updatedNote.author, snap.data!);
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          RichText(
                                            text: TextSpan(
                                              children: [
                                                TextSpan(
                                                  text: user.name.length > 25
                                                      ? '${user.name.substring(0, 25)}'
                                                      : user.name,
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                if (user.nip05.isNotEmpty &&
                                                    user.nip05.contains('@'))
                                                  TextSpan(
                                                    text:
                                                        ' @${user.nip05.split('@').last}',
                                                    style: const TextStyle(
                                                      fontSize: 15,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                TextSpan(
                                                  text:
                                                      ' • ${_formatTimestamp(updatedNote.timestamp)}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 2),
                            if ((parsed['textParts'] as List).isNotEmpty)
                              _buildContentText(parsed),
                            if ((parsed['mediaUrls'] as List).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: MediaPreviewWidget(
                                  mediaUrls:
                                      parsed['mediaUrls'] as List<String>,
                                ),
                              ),
                            if ((parsed['linkUrls'] as List).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Column(
                                  children: (parsed['linkUrls'] as List<String>)
                                      .map((u) => LinkPreviewWidget(url: u))
                                      .toList(),
                                ),
                              ),
                            if ((parsed['quoteIds'] as List).isNotEmpty)
                              Column(
                                children: (parsed['quoteIds'] as List<String>)
                                    .map((q) => QuoteWidget(
                                        bech32: q,
                                        dataService: widget.dataService))
                                    .toList(),
                              ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _buildAction(
                                  scale: _reactionScale,
                                  svg: 'assets/reaction_button.svg',
                                  color: _isReactionGlowing || _hasReacted()
                                      ? Colors.red.shade400
                                      : Colors.white,
                                  count: updatedNote.reactionCount,
                                  onTap: _handleReactionTap,
                                ),
                                _buildAction(
                                  scale: _replyScale,
                                  svg: 'assets/reply_button.svg',
                                  color: _isReplyGlowing || _hasReplied()
                                      ? Colors.blue.shade200
                                      : Colors.white,
                                  count: updatedNote.replyCount,
                                  onTap: _handleReplyTap,
                                ),
                                _buildAction(
                                  scale: _repostScale,
                                  svg: 'assets/repost_button.svg',
                                  color: _isRepostGlowing || _hasReposted()
                                      ? Colors.green.shade400
                                      : Colors.white,
                                  count: updatedNote.repostCount,
                                  onTap: _handleRepostTap,
                                ),
                                _buildAction(
                                  scale: _zapScale,
                                  svg: 'assets/zap_button.svg',
                                  color: _isZapGlowing
                                      ? Colors.amber.shade300
                                      : Colors.white,
                                  count: 0,
                                  onTap: _handleZapTap,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
