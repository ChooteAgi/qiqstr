import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/theme_manager.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:qiqstr/models/user_model.dart';
import 'package:qiqstr/screens/edit_profile.dart';
import 'package:qiqstr/screens/following_page.dart';
import 'package:qiqstr/services/data_service.dart';
import 'package:hive/hive.dart';
import 'package:qiqstr/models/following_model.dart';
import 'package:qiqstr/widgets/mini_link_preview_widget.dart';
import 'package:qiqstr/widgets/photo_viewer_widget.dart';
import 'package:nostr_nip19/nostr_nip19.dart';

class ProfileInfoWidget extends StatefulWidget {
  final UserModel user;

  const ProfileInfoWidget({super.key, required this.user});

  @override
  State<ProfileInfoWidget> createState() => _ProfileInfoWidgetState();
}

class _ProfileInfoWidgetState extends State<ProfileInfoWidget> {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  bool? _isFollowing;
  String? _currentUserNpub;
  late Box<FollowingModel> _followingBox;
  DataService? _dataService;

  int? _followingCount;
  bool _isLoadingFollowing = true;
  bool _followsYou = false;

  UserModel? _liveUser;
  Timer? _userRefreshTimer;
  bool _copiedToClipboard = false;

  @override
  void initState() {
    super.initState();
    _initFollowStatus();
    _loadFollowingCount();
    _startUserRefreshTimer();
  }

  @override
  void dispose() {
    _userRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initFollowStatus() async {
    _currentUserNpub = await _secureStorage.read(key: 'npub');
    if (_currentUserNpub == null || _currentUserNpub == widget.user.npub)
      return;

    _followingBox = await Hive.openBox<FollowingModel>('followingBox');
    final model = _followingBox.get('following_$_currentUserNpub');
    final isFollowing = model?.pubkeys.contains(widget.user.npub) ?? false;
    setState(() {
      _isFollowing = isFollowing;
    });

    _dataService =
        DataService(npub: _currentUserNpub!, dataType: DataType.profile);
    await _dataService!.initialize();
  }

  void _startUserRefreshTimer() {
    final npub = widget.user.npub;
    _userRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final usersBox = await Hive.openBox<UserModel>('users');
      final latestUser = usersBox.get(npub);
      if (latestUser != null && mounted) {
        setState(() {
          _liveUser = latestUser;
        });
      }
    });
  }

  Future<void> _loadFollowingCount() async {
    try {
      final dataService =
          DataService(npub: widget.user.npub, dataType: DataType.profile);
      await dataService.initialize();
      final followingList =
          await dataService.getFollowingList(widget.user.npub);

      final currentNpub = await _secureStorage.read(key: 'npub');
      final followsYou = currentNpub != null &&
          widget.user.npub != currentNpub &&
          followingList.contains(currentNpub);

      setState(() {
        _followingCount = followingList.length;
        _isLoadingFollowing = false;
        _followsYou = followsYou;
        _currentUserNpub = currentNpub;
      });
    } catch (e) {
      setState(() {
        _isLoadingFollowing = false;
      });
    }
  }

  Future<void> _toggleFollow() async {
    if (_currentUserNpub == null || _dataService == null) return;

    setState(() {
      _isFollowing = !_isFollowing!;
    });

    try {
      if (_isFollowing!) {
        await _dataService!.sendFollow(widget.user.npub);
      } else {
        await _dataService!.sendUnfollow(widget.user.npub);
      }
    } catch (e) {
      setState(() {
        _isFollowing = !_isFollowing!;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _liveUser ?? widget.user;
    final npubBech32 = encodeBasicBech32(user.npub, "npub");
    final screenWidth = MediaQuery.of(context).size.width;
    final websiteUrl = user.website.isNotEmpty &&
            !(user.website.startsWith("http://") ||
                user.website.startsWith("https://"))
        ? "https://${user.website}"
        : user.website;

    return Container(
      color: context.colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              if (user.banner.isNotEmpty) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        PhotoViewerWidget(imageUrls: [user.banner]),
                  ),
                );
              }
            },
            child: CachedNetworkImage(
              imageUrl: user.banner,
              width: screenWidth,
              height: 130,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                height: 130,
                width: screenWidth,
                color: context.colors.grey700,
              ),
              errorWidget: (_, __, ___) => Container(
                height: 130,
                width: screenWidth,
                color: context.colors.background,
              ),
            ),
          ),
          Container(
            transform: Matrix4.translationValues(0, -30, 0),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (user.profileImage.isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PhotoViewerWidget(
                                  imageUrls: [user.profileImage]),
                            ),
                          );
                        }
                      },
                      child: _buildAvatar(user),
                    ),
                    const Spacer(),
                    if (_currentUserNpub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 35.0),
                        child: (widget.user.npub == _currentUserNpub)
                            ? GestureDetector(
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const EditOwnProfilePage(),
                                    ),
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  height: 34,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: context.colors.overlayLight,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(color: context.colors.borderAccent),
                                  ),
                                  child: Text(
                                    'Edit profile',
                                    style: TextStyle(
                                      color: context.colors.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              )
                            : (_isFollowing != null)
                                ? GestureDetector(
                                    onTap: _toggleFollow,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16),
                                      height: 34,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: context.colors.overlayLight,
                                        borderRadius: BorderRadius.circular(24),
                                        border:
                                            Border.all(color: context.colors.borderAccent),
                                      ),
                                      child: Text(
                                        _isFollowing! ? 'Following' : 'Follow',
                                        style: TextStyle(
                                          color: context.colors.textPrimary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildNameRow(context, user),
                const SizedBox(height: 6),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: npubBech32));
                    setState(() => _copiedToClipboard = true);
                    await Future.delayed(const Duration(seconds: 1));
                    if (mounted) setState(() => _copiedToClipboard = false);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.colors.overlayLight,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: context.colors.borderAccent),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Row(
                        key: ValueKey(_copiedToClipboard),
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.copy,
                              size: 14, color: context.colors.textTertiary),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _copiedToClipboard
                                  ? 'Copied to clipboard'
                                  : npubBech32,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: context.colors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (user.lud16.isNotEmpty)
                  Text(user.lud16, style: TextStyle(fontSize: 13, color: context.colors.accent)),
                if (user.about.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(user.about,
                        style: TextStyle(
                            fontSize: 14, color: context.colors.secondary)),
                  ),
                if (user.website.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: MiniLinkPreviewWidget(url: websiteUrl),
                  ),
                const SizedBox(height: 16),
                _buildFollowingCount(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(UserModel user) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: context.colors.background, width: 3),
      ),
      child: CircleAvatar(
        radius: 40,
        backgroundImage: user.profileImage.isNotEmpty
            ? CachedNetworkImageProvider(user.profileImage)
            : null,
        backgroundColor: user.profileImage.isEmpty ? context.colors.secondary : null,
        child: user.profileImage.isEmpty
            ? Icon(Icons.person, size: 40, color: context.colors.textPrimary)
            : null,
      ),
    );
  }

  Widget _buildNameRow(BuildContext context, UserModel user) {
    return Row(
      children: [
        Flexible(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 24),
              children: [
                TextSpan(
                  text: user.name.isNotEmpty
                      ? user.name
                      : user.nip05.split('@').first,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: context.colors.textPrimary,
                  ),
                ),
                if (user.nip05.isNotEmpty && user.nip05.contains('@'))
                  const TextSpan(text: '\u200A'),
                if (user.nip05.isNotEmpty && user.nip05.contains('@'))
                  TextSpan(
                    text: '@${user.nip05.split('@').last}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: context.colors.accent,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFollowingCount() {
    return Row(
      children: [
        Text('Following: ',
            style: TextStyle(color: context.colors.textSecondary, fontSize: 14)),
        GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => FollowingListPage(
                  display_name: (_liveUser ?? widget.user).name.isNotEmpty
                      ? (_liveUser ?? widget.user).name
                      : (_liveUser ?? widget.user).nip05.split('@').first,
                  npub: (_liveUser ?? widget.user).npub,
                ),
              ),
            );
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: _isLoadingFollowing
                ? Text(
                    '...',
                    key: const ValueKey('loading'),
                    style: TextStyle(
                        color: context.colors.textTertiary,
                        fontSize: 14,
                        decoration: TextDecoration.underline),
                  )
                : Text(
                    '$_followingCount',
                    key: const ValueKey('count'),
                    style: TextStyle(
                        color: context.colors.textPrimary,
                        fontSize: 14,
                        decoration: TextDecoration.underline),
                  ),
          ),
        ),
        if (_followsYou) ...[
          const SizedBox(width: 8),
          Text(
            '• Follows you',
            style: TextStyle(
              color: context.colors.success,
              fontSize: 13,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ],
    );
  }
}
