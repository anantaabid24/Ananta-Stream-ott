import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const String appName = 'Ananta OTT';
const String playlistUrl =
    'https://raw.githubusercontent.com/anantaabid24/Ananta-Ott/refs/heads/main/channels.m3u';
const String ptvStreamUrl =
    'http://103.185.24.134:3001/ptv/index.m3u8';

const Color accentColor = Color(0xFF9B87FF);
const Color backgroundColor = Color(0xFF090914);
const Color glassColor = Color(0xFF211F35);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AnantaOttApp());
}

class Channel {
  final String name;
  final String url;
  final String group;
  final String logo;
  const Channel({
    required this.name,
    required this.url,
    this.group = 'Live TV',
    this.logo = '',
  });
}

const Channel ptvChannel = Channel(
  name: 'PTV ',
  url: ptvStreamUrl,
  group: 'Sports',
);

class AnantaOttApp extends StatelessWidget {
  const AnantaOttApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accentColor,
          brightness: Brightness.dark,
        ),
      ),
      home: const AnantaHomePage(),
    );
  }
}

class AnantaHomePage extends StatefulWidget {
  const AnantaHomePage({super.key});
  @override
  State<AnantaHomePage> createState() => _AnantaHomePageState();
}

class _AnantaHomePageState extends State<AnantaHomePage> {
  final TextEditingController _searchController = TextEditingController();
  List<Channel> _channels = [ptvChannel];
  Set<String> _favorites = {};
  VideoPlayerController? _player;
  Channel? _selectedChannel;
  Timer? _controlsTimer;
  String _selectedCategory = 'All';
  String _searchQuery = '';
  String _status = 'Ready';
  String? _playerError;
  bool _loadingPlaylist = false;
  bool _connecting = false;
  bool _showFavoritesOnly = false;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  int _playlistRequestId = 0;
  int _playRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    _loadPlaylist();
  }

  // --------------------------------------------------
  // GLASS EFFECT + PRO THEME
  // --------------------------------------------------
  Widget _glass({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(10),
    double radius = 16,
    Color color = glassColor,
  }) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: color.withOpacity(0.85),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // FAVORITES
  // --------------------------------------------------
  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _favorites = (prefs.getStringList('ananta_favorites') ?? []).toSet());
    } catch (e) {
      debugPrint('Favorites error: $e');
    }
  }

  Future<void> _saveFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ananta_favorites', _favorites.toList());
    } catch (e) {
      debugPrint('Saving favorites failed: $e');
    }
  }

  Future<void> _toggleFavorite(Channel channel) async {
    setState(() {
      if (_favorites.contains(channel.url)) _favorites.remove(channel.url);
      else _favorites.add(channel.url);
    });
    await _saveFavorites();
  }

  // --------------------------------------------------
  // M3U PARSER
  // --------------------------------------------------
  String _attribute(String line, String attribute) {
    final pattern = RegExp(
      '$attribute\\s*=\\s*["\\x27]([^"\\x27]*)',
      caseSensitive: false,
    );
    return pattern.firstMatch(line)?.group(1) ?? '';
  }

  List<Channel> _parseM3u(String content) {
    final result = <Channel>[];
    final lines = content.split(RegExp(r'\r?\n'));
    String? name;
    String group = 'Live TV';
    String logo = '';
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        final comma = line.lastIndexOf(',');
        name = comma >= 0 ? line.substring(comma + 1).trim() : 'Unknown channel';
        group = _attribute(line, 'group-title');
        logo = _attribute(line, 'tvg-logo');
        if (group.isEmpty) group = 'Live TV';
      } else if (!line.startsWith('#') && name != null) {
        final uri = Uri.tryParse(line);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
          result.add(Channel(name: name, url: line, group: group, logo: logo));
        }
        name = null;
        group = 'Live TV';
        logo = '';
      }
    }
    return result;
  }

  // --------------------------------------------------
  // PLAYLIST (fast)
  // --------------------------------------------------
  Future<void> _loadPlaylist() async {
    if (_loadingPlaylist) return;
    final requestId = ++_playlistRequestId;
    setState(() {
      _loadingPlaylist = true;
      _status = 'Loading latest playlist...';
    });
    try {
      final baseUri = Uri.parse(playlistUrl);
      final query = Map<String, String>.from(baseUri.queryParameters);
      query['_refresh'] = DateTime.now().millisecondsSinceEpoch.toString();
      final uri = baseUri.replace(queryParameters: query);
      final response = await http
          .get(uri, headers: const {
            'User-Agent': 'AnantaOTT/1.0',
            'Accept': '*/*',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
          })
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw Exception('Playlist server returned HTTP ${response.statusCode}');
      final parsed = _parseM3u(response.body);
      if (parsed.isEmpty) throw Exception('No valid channels found in the M3U file.');
      final updated = <Channel>[ptvChannel];
      final seen = <String>{ptvChannel.url};
      for (final channel in parsed) {
        if (seen.add(channel.url)) updated.add(channel);
      }
      if (!mounted || requestId != _playlistRequestId) return;
      final groups = updated.map((c) => c.group).toSet();
      setState(() {
        _channels = updated;
        if (_selectedCategory != 'All' && !groups.contains(_selectedCategory)) _selectedCategory = 'All';
        _status = '${updated.length} channels loaded';
      });
    } catch (e) {
      debugPrint('Playlist refresh error: $e');
      if (!mounted || requestId != _playlistRequestId) return;
      setState(() => _status = 'Refresh failed; existing channels retained');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playlist refresh failed: $e'), action: SnackBarAction(label: 'Retry', onPressed: _loadPlaylist)),
      );
    } finally {
      if (mounted && requestId == _playlistRequestId) setState(() => _loadingPlaylist = false);
    }
  }

  // --------------------------------------------------
  // CONTROLS
  // --------------------------------------------------
  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_player?.value.isInitialized == true) setState(() => _controlsVisible = false);
    });
  }

  void _showPlayerControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    if (_player?.value.isInitialized == true) _scheduleControlsHide();
  }

  void _togglePlayerControls() {
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showPlayerControls();
    }
  }

  // --------------------------------------------------
  // PLAYBACK
  // --------------------------------------------------
  Future<void> _playChannel(Channel channel) async {
    if (_connecting) return;
    final requestId = ++_playRequestId;
    final oldPlayer = _player;
    _controlsTimer?.cancel();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(channel.url),
      httpHeaders: const {
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
    );
    setState(() {
      _player = controller;
      _selectedChannel = channel;
      _playerError = null;
      _connecting = true;
      _controlsVisible = true;
      _status = 'Connecting to ${channel.name}...';
    });
    try {
      await oldPlayer?.dispose();
      await controller.initialize().timeout(const Duration(seconds: 35));
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      if (controller.value.hasError) throw Exception(controller.value.errorDescription ?? 'Player error');
      await controller.play();
      if (!mounted || requestId != _playRequestId) return;
      setState(() {
        _status = 'Playing ${channel.name}';
        _connecting = false;
      });
      _scheduleControlsHide();
    } on TimeoutException {
      await controller.dispose();
      if (!mounted || requestId != _playRequestId) return;
      setState(() {
        _player = null;
        _playerError = 'Connection timed out. Please retry.';
        _status = 'Connection timed out';
        _connecting = false;
      });
    } catch (e) {
      debugPrint('Playback error for ${channel.url}: $e');
      await controller.dispose();
      if (!mounted || requestId != _playRequestId) return;
      setState(() {
        _player = null;
        _playerError = e.toString();
        _status = 'Playback failed';
        _connecting = false;
      });
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    try {
      if (player.value.isPlaying) await player.pause();
      else await player.play();
      if (!mounted) return;
      setState(() {});
      _showPlayerControls();
    } catch (e) {
      debugPrint('Playback control error: $e');
    }
  }

  Future<void> _changeChannel(int direction) async {
    final list = _visibleChannels;
    if (list.isEmpty || _connecting) return;
    final currentIndex = list.indexWhere((channel) => channel.url == _selectedChannel?.url);
    final nextIndex = currentIndex == -1
        ? (direction > 0 ? 0 : list.length - 1)
        : (currentIndex + direction + list.length) % list.length;
    await _playChannel(list[nextIndex]);
  }

  // --------------------------------------------------
  // FULLSCREEN - FIXED (phone no longer locks)
  // --------------------------------------------------
  Future<void> _setFullscreen(bool value) async {
    if (value) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: [SystemUiOverlay.statusBar],
      );
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: [SystemUiOverlay.statusBar],
      );
    }
    if (!mounted) return;
    setState(() {
      _fullscreen = value;
      _controlsVisible = true;
    });
    _scheduleControlsHide();
  }

  Future<bool> _handleBack() async {
    if (_fullscreen) {
      await _setFullscreen(false);
      return false;
    }
    return true;
  }

  // --------------------------------------------------
  // CATEGORIES
  // --------------------------------------------------
  List<String> get _categories {
    final groups = _channels
        .map((channel) => channel.group.trim())
        .where((group) => group.isNotEmpty)
        .toSet()
        .toList();
    groups.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ['All', ...groups];
  }

  List<Channel> get _visibleChannels {
    final query = _searchQuery.trim().toLowerCase();
    return _channels.where((channel) {
      final matchesCategory = _selectedCategory == 'All' || channel.group == _selectedCategory;
      final matchesSearch = channel.name.toLowerCase().contains(query) || channel.group.toLowerCase().contains(query);
      final matchesFavorite = !_showFavoritesOnly || _favorites.contains(channel.url);
      return matchesCategory && matchesSearch && matchesFavorite;
    }).toList();
  }

  // --------------------------------------------------
  // PLAYER UI
  // --------------------------------------------------
  Widget _buildPlayer({required bool fullscreen}) {
    final player = _player;
    final initialized = player?.value.isInitialized == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: initialized ? _togglePlayerControls : null,
      child: Container(
        width: double.infinity,
        height: fullscreen ? double.infinity : 220,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (initialized)
              Center(
                child: AspectRatio(
                  aspectRatio: player!.value.aspectRatio > 0 ? player.value.aspectRatio : 16 / 9,
                  child: VideoPlayer(player),
                ),
              )
            else
              Center(
                child: _connecting
                    ? const CircularProgressIndicator(color: accentColor)
                    : Icon(_playerError == null ? Icons.live_tv : Icons.error_outline,
                        size: 48, color: _playerError == null ? accentColor : Colors.redAccent),
              ),
            if (_controlsVisible) ...[
              Positioned(
                top: 8,
                left: 10,
                right: 10,
                child: _glass(
                  radius: 12,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                  child: Row(
                    children: [
                      const Icon(Icons.circle, size: 8, color: Colors.redAccent),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(_selectedChannel?.name ?? appName,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      ),
                      IconButton(
                        tooltip: 'Fullscreen',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                        padding: EdgeInsets.zero,
                        onPressed: () => _setFullscreen(!_fullscreen),
                        icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, size: 21),
                      ),
                    ],
                  ),
                ),
              ),
              if (initialized)
                Center(
                  child: _glass(
                    radius: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Previous',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          padding: EdgeInsets.zero,
                          onPressed: () => _changeChannel(-1),
                          icon: const Icon(Icons.skip_previous_rounded, size: 23),
                        ),
                        IconButton(
                          tooltip: 'Play / Pause',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                          padding: EdgeInsets.zero,
                          onPressed: _togglePlayback,
                          icon: Icon(player!.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 30),
                        ),
                        IconButton(
                          tooltip: 'Next',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          padding: EdgeInsets.zero,
                          onPressed: () => _changeChannel(1),
                          icon: const Icon(Icons.skip_next_rounded, size: 23),
                        ),
                      ],
                    ),
                  ),
                ),
              if (initialized)
                Positioned(
                  bottom: 8,
                  left: 10,
                  right: 10,
                  child: _glass(
                    radius: 10,
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: VideoProgressIndicator(
                            player!,
                            allowScrubbing: true,
                            padding: EdgeInsets.zero,
                            colors: const VideoProgressColors(
                              playedColor: accentColor,
                              bufferedColor: Colors.white38,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Favorite',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                          padding: EdgeInsets.zero,
                          onPressed: _selectedChannel == null
                              ? null
                              : () => _toggleFavorite(_selectedChannel!),
                          icon: Icon(
                            _selectedChannel != null && _favorites.contains(_selectedChannel!.url)
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 19,
                            color: Colors.pinkAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_playerError != null)
                Center(
                  child: FilledButton.icon(
                    onPressed: _selectedChannel == null ? null : () => _playChannel(_selectedChannel!),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry stream'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------
  // CATEGORIES
  // --------------------------------------------------
  Widget _buildCategories() {
    return RepaintBoundary(
      child: SizedBox(
        height: 46,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          scrollDirection: Axis.horizontal,
          itemCount: _categories.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final category = _categories[index];
            final selected = _selectedCategory == category;
            return ChoiceChip(
              label: Text(category),
              selected: selected,
              showCheckmark: false,
              backgroundColor: glassColor,
              selectedColor: accentColor,
              labelStyle: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
              onSelected: (_) => setState(() => _selectedCategory = category),
            );
          },
        ),
      ),
    );
  }

  // --------------------------------------------------
  // CHANNEL TILE
  // --------------------------------------------------
  Widget _buildChannelTile(Channel channel) {
    final selected = _selectedChannel?.url == channel.url;
    final favorite = _favorites.contains(channel.url);

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: _glass(
          radius: 15,
          padding: EdgeInsets.zero,
          color: selected ? const Color(0xFF373052) : glassColor,
          child: Focus(
            onFocusChange: (hasFocus) {
              if (hasFocus) {
                setState(() => _selectedChannel = channel);
              }
            },
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _playChannel(channel),
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  leading: CircleAvatar(
                    radius: 21,
                    backgroundColor: accentColor.withOpacity(0.17),
                    backgroundImage: channel.logo.isNotEmpty ? NetworkImage(channel.logo) : null,
                    child: channel.logo.isEmpty
                        ? const Icon(Icons.live_tv, color: accentColor, size: 21)
                        : null,
                  ),
                  title: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                      color: selected ? Colors.white : null,
                    ),
                  ),
                  subtitle: Text(
                    channel.group,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  trailing: IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                    onPressed: (e) {
                      e.stopPropagation();
                      _toggleFavorite(channel);
                    },
                    icon: Icon(
                      favorite ? Icons.favorite : Icons.favorite_border,
                      color: favorite ? Colors.pinkAccent : Colors.white54,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // DISPOSE
  // --------------------------------------------------
  @override
  void dispose() {
    _controlsTimer?.cancel();
    _playlistRequestId++;
    _playRequestId++;
    _searchController.dispose();
    _player?.dispose();

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    super.dispose();
  }

  // --------------------------------------------------
  // MAIN SCREEN
  // --------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final channels = _visibleChannels;
    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        appBar: _fullscreen
            ? null
            : AppBar(
                backgroundColor: backgroundColor,
                title: const Row(
                  children: [
                    Icon(Icons.blur_on, color: accentColor, size: 29),
                    SizedBox(width: 8),
                    Text('Ananta OTT', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.3)),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'Favorites',
                    onPressed: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
                    icon: Icon(_showFavoritesOnly ? Icons.favorite : Icons.favorite_border),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loadingPlaylist ? null : _loadPlaylist,
                    icon: _loadingPlaylist
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: accentColor))
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
        body: _fullscreen
            ? _buildPlayer(fullscreen: true)
            : Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF19152B), backgroundColor, Color(0xFF101020)],
                  ),
                ),
                child: Column(
                  children: [
                    _buildPlayer(fullscreen: false),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      child: Row(
                        children: [
                          const Expanded(child: Text('Explore channels', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
                          Text('${channels.length} channels', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: _glass(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        radius: 15,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => setState(() => _searchQuery = value),
                          decoration: InputDecoration(
                            hintText: 'Search channels...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchQuery.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                    icon: const Icon(Icons.clear),
                                  ),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildCategories(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ),
                    ),
                    Expanded(
                      child: channels.isEmpty
                          ? Center(child: Text(_showFavoritesOnly ? 'No favorites in this category' : 'No channels found', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)))
                          : FocusScope(
                              child: ListView.builder(
                                key: ValueKey('$_selectedCategory-$_showFavoritesOnly-$_searchQuery'),
                                itemCount: channels.length,
                                itemBuilder: (context, index) {
                                  return _buildChannelTile(channels[index]);
                                },
                              ),
                            ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
