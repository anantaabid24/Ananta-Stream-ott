import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String appName = 'Ananta OTT';
const String playlistUrl =
    'https://raw.githubusercontent.com/anantaabid24/Ananta-Ott/refs/heads/main/channels.m3u';
const String ptvStreamUrl =
    'http://103.185.24.134:3001/ptv/index.m3u8';
const List<String> epgSourceUrls = [
  'https://avkb.short.gy/tsepg.xml.gz',
  'https://avkb.short.gy/jioepg.xml.gz',
  'https://avkb.short.gy/epg.xml.gz',
];

const Color accentColor = Color(0xFF9B87FF);
const Color backgroundColor = Color(0xFF090914);
const Color glassColor = Color(0xFF211F35);

String _epgAttribute(String text, String name) {
  final match = RegExp('\\b${RegExp.escape(name)}\\s*=\\s*["\\x27]([^"\\x27]*)', caseSensitive: false).firstMatch(text);
  return match?.group(1) ?? '';
}

String _epgDecodeText(String value) => value
    .replaceAll('<![CDATA[', '')
    .replaceAll(']]>', '')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

String _epgTagText(String block, String tag) {
  final match = RegExp('<$tag\\b[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true).firstMatch(block);
  return match == null ? '' : _epgDecodeText(match.group(1) ?? '');
}

DateTime? _epgParseTime(String value) {
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?').firstMatch(value.trim());
  if (match == null) return null;
  try {
    final clockAsUtc = DateTime.utc(
      int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!),
      int.parse(match.group(4)!), int.parse(match.group(5)!), int.parse(match.group(6)!),
    );
    final sign = match.group(7);
    if (sign == null) return clockAsUtc;
    final offset = int.parse(match.group(8)!) * 60 + int.parse(match.group(9)!);
    return clockAsUtc.subtract(Duration(minutes: sign == '+' ? offset : -offset));
  } catch (_) {
    return null;
  }
}

// Runs in a background isolate so decompression and XMLTV scanning do not
// block the TV player's frame rendering.
Map<String, dynamic> _parseEpgPayload(List<int> payload) {
  var bytes = payload;
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    bytes = gzip.decode(bytes);
  }
  final xml = utf8.decode(bytes, allowMalformed: true);
  final namesById = <String, List<String>>{};
  final logosById = <String, String>{};
  final channelPattern = RegExp(r'<channel\b([^>]*)>(.*?)</channel\s*>', caseSensitive: false, dotAll: true);
  for (final match in channelPattern.allMatches(xml)) {
    final id = _epgAttribute(match.group(1) ?? '', 'id').trim();
    if (id.isEmpty) continue;
    final names = RegExp(r'<display-name\b[^>]*>(.*?)</display-name\s*>', caseSensitive: false, dotAll: true)
        .allMatches(match.group(2) ?? '')
        .map((m) => _epgDecodeText(m.group(1) ?? ''))
        .where((name) => name.isNotEmpty).toSet().toList();
    if (names.isNotEmpty) namesById[id] = names;
    final iconMatch = RegExp(r'<icon\b([^>]*)\/?\s*>', caseSensitive: false).firstMatch(match.group(2) ?? '');
    final iconUrl = _epgAttribute(iconMatch?.group(1) ?? '', 'src').trim();
    if (iconUrl.startsWith('https://') || iconUrl.startsWith('http://')) logosById[id] = iconUrl;
  }
  final now = DateTime.now().toUtc();
  final programmes = <Map<String, dynamic>>[];
  final programmePattern = RegExp(r'<programme\b([^>]*)>(.*?)</programme\s*>', caseSensitive: false, dotAll: true);
  for (final match in programmePattern.allMatches(xml)) {
    final attrs = match.group(1) ?? '';
    final body = match.group(2) ?? '';
    final id = _epgAttribute(attrs, 'channel').trim();
    if (id.isEmpty) continue;
    final start = _epgParseTime(_epgAttribute(attrs, 'start'));
    final stop = _epgParseTime(_epgAttribute(attrs, 'stop'));
    if (start == null || stop == null ||
        !stop.isAfter(now.subtract(const Duration(days: 3))) ||
        start.isAfter(now.add(const Duration(days: 3)))) continue;
    final title = _epgTagText(body, 'title');
    if (title.isEmpty) continue;
    programmes.add(<String, dynamic>{
      'id': id,
      'title': title,
      'description': _epgTagText(body, 'desc'),
      'start': start.millisecondsSinceEpoch,
      'stop': stop.millisecondsSinceEpoch,
    });
  }
  return <String, dynamic>{'namesById': namesById, 'logosById': logosById, 'programmes': programmes};
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AnantaOttApp());
}

class Channel {
  final String name;
  final String url;
  final String group;
  final String logo;
  final String tvgId;
  final String tvgName;
  const Channel({
    required this.name,
    required this.url,
    this.group = 'Live TV',
    this.logo = '',
    this.tvgId = '',
    this.tvgName = '',
  });
}

class EpgProgram {
  final String title;
  final String description;
  final DateTime start;
  final DateTime stop;
  const EpgProgram({
    required this.title,
    required this.description,
    required this.start,
    required this.stop,
  });

  bool isAiringAt(DateTime time) => !time.isBefore(start) && time.isBefore(stop);
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
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
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
  VideoPlayerController? _pendingPlayer;
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
  // TV starts with an unobstructed full-screen player; Enter opens the rail.
  bool _tvSidebarVisible = false;
  bool _tvShowingCategories = false;
  bool _tvEpgVisible = false;
  bool _epgLoading = false;
  int _tvFocusedChannelIndex = 0;
  int _tvFocusedCategoryIndex = 0;
  final ScrollController _tvChannelScrollController = ScrollController();
  final ScrollController _tvCategoryScrollController = ScrollController();
  final FocusNode _tvPlayerFocusNode = FocusNode(debugLabel: 'tv-player');
  final FocusNode _tvSearchFocusNode = FocusNode(debugLabel: 'tv-channel-search');
  final Map<String, FocusNode> _tvChannelFocusNodes = {};
  Map<String, List<EpgProgram>> _epgById = {};
  Map<String, List<EpgProgram>> _epgByName = {};
  Map<String, List<EpgProgram>> _epgByChannelUrl = {};
  Map<String, String> _epgLogosById = {};
  Map<String, String> _epgLogosByName = {};
  String _epgStatus = 'Loading programme guide…';
  Timer? _epgClock;
  Timer? _epgRefreshTimer;
  int _playlistRequestId = 0;
  int _playRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    _loadPlaylist();
    _initializeEpg();
    _epgClock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _epgRefreshTimer = Timer.periodic(const Duration(hours: 2), (_) => _loadEpg());
  }

  // Xiaomi Mi Box / Android TV remote handling. Focus and index are managed
  // explicitly, and KeyRepeatEvent is supported so held D-pad directions browse
  // long channel lists smoothly rather than moving only one row per press.
  void _focusTvChannel(int index, {bool requestFocus = true}) {
    final channels = _visibleChannels;
    if (channels.isEmpty) return;
    final safeIndex = index.clamp(0, channels.length - 1).toInt();
    setState(() {
      _tvFocusedChannelIndex = safeIndex;
      _tvSidebarVisible = true;
      _tvEpgVisible = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_tvChannelScrollController.hasClients) return;
      // Scroll first so ListView builds the destination row before requesting
      // its FocusNode. Requesting focus before this point fails for off-screen
      // rows and makes UP/DOWN appear to stop working on Android TV.
      // Use an immediate scroll for D-pad repeat events. Queuing an animation
      // for every repeated key caused focus to lag behind the remote on Mi Box.
      final target = (safeIndex * 96.0).clamp(
        0.0,
        _tvChannelScrollController.position.maxScrollExtent,
      ).toDouble();
      if ((_tvChannelScrollController.offset - target).abs() > 1) {
        _tvChannelScrollController.jumpTo(target);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !requestFocus) return;
      final node = _tvChannelFocusNodes[channels[safeIndex].url];
      if (node != null && node.canRequestFocus) node.requestFocus();
    });
  }

  void _focusTvPlayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvPlayerFocusNode.canRequestFocus) return;
      _tvPlayerFocusNode.requestFocus();
    });
  }

  void _focusTvCategory(int index) {
    final categories = _categories;
    if (categories.isEmpty) return;
    setState(() {
      _tvSidebarVisible = true;
      _tvShowingCategories = true;
      _tvFocusedCategoryIndex = index.clamp(0, categories.length - 1).toInt();
    });
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvCategoryScrollController.hasClients) return;
      final target = (_tvFocusedCategoryIndex * 58.0).clamp(
        0.0, _tvCategoryScrollController.position.maxScrollExtent,
      ).toDouble();
      if ((_tvCategoryScrollController.offset - target).abs() > 1) {
        _tvCategoryScrollController.jumpTo(target);
      }
    });
    _focusTvPlayer();
  }

  void _moveTvCategory(int delta) {
    final categories = _categories;
    if (categories.isEmpty) return;
    setState(() {
      _tvFocusedCategoryIndex =
          (_tvFocusedCategoryIndex + delta).clamp(0, categories.length - 1).toInt();
    });
    // Keep the currently focused player key handler active while browsing;
    // do not unfocus/refocus on every repeated D-pad event.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvCategoryScrollController.hasClients) return;
      final target = (_tvFocusedCategoryIndex * 58.0).clamp(
        0.0, _tvCategoryScrollController.position.maxScrollExtent,
      ).toDouble();
      if ((_tvCategoryScrollController.offset - target).abs() > 1) {
        _tvCategoryScrollController.jumpTo(target);
      }
    });
  }

  void _showTvChannels({int? index}) {
    if (!mounted) return;
    final channels = _visibleChannels;
    final safeIndex = channels.isEmpty
        ? 0
        : (index ?? _tvFocusedChannelIndex).clamp(0, channels.length - 1).toInt();
    // One state update only: the old implementation called _focusTvChannel,
    // which performed a second setState and another scroll/focus pass on every
    // Enter press. On low-memory TV boxes that made the live video stutter.
    setState(() {
      _tvShowingCategories = false;
      _tvSidebarVisible = true;
      _tvEpgVisible = false;
      _tvFocusedChannelIndex = safeIndex;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_tvChannelScrollController.hasClients || channels.isEmpty) return;
      final maxExtent = _tvChannelScrollController.position.maxScrollExtent;
      final target = (safeIndex * 96.0).clamp(0.0, maxExtent).toDouble();
      if ((_tvChannelScrollController.offset - target).abs() > 1) {
        _tvChannelScrollController.jumpTo(target);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final focus = _tvChannelFocusNodes[channels[safeIndex].url];
      if (focus != null && focus.canRequestFocus) focus.requestFocus();
    });
  }

  KeyEventResult _handleRemoteKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final primaryContext = FocusManager.instance.primaryFocus?.context;
    final key = event.logicalKey;
    final isConfirmKey = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    // Some TV remotes emit confirm-key repeat events when the button is held.
    // Do not repeatedly rebuild the sidebar or issue duplicate playback requests.
    if (isConfirmKey && event is KeyRepeatEvent) return KeyEventResult.handled;
    final channels = _visibleChannels;
    final categories = _categories;
    final editingSearch = primaryContext?.widget is EditableText;

    // Search remains usable with the TV keyboard. D-pad UP opens categories;
    // DOWN moves into results, avoiding a focus trap inside the text field.
    if (editingSearch) {
      if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
        FocusManager.instance.primaryFocus?.unfocus();
        _showTvChannels(index: 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        FocusManager.instance.primaryFocus?.unfocus();
        _showTvChannels(index: 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, categories.length - 1).toInt());
        return KeyEventResult.handled;
      }
      if (key != LogicalKeyboardKey.escape && key != LogicalKeyboardKey.browserBack) {
        return KeyEventResult.ignored;
      }
    }

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      if (_tvShowingCategories) {
        _moveTvCategory(delta);
        return KeyEventResult.handled;
      }
      if (channels.isEmpty) return KeyEventResult.handled;
      if (!_tvSidebarVisible) {
        // The hidden rail is deliberately inert. Only Enter/Select may open it;
        // directional keys must never zap or reveal channels unexpectedly.
        return KeyEventResult.handled;
      }
      final currentFocus = FocusManager.instance.primaryFocus;
      if (currentFocus == _tvSearchFocusNode) {
        FocusManager.instance.primaryFocus?.unfocus();
        _showTvChannels(index: 0);
      } else {
        _focusTvChannel((_tvFocusedChannelIndex + delta).clamp(0, channels.length - 1).toInt());
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
      if (!_tvSidebarVisible) {
        final current = channels.indexWhere((c) => c.url == _selectedChannel?.url);
        _showTvChannels(index: current >= 0 ? current : _tvFocusedChannelIndex);
      } else if (_tvShowingCategories) {
        if (categories.isNotEmpty) {
          final category = categories[_tvFocusedCategoryIndex.clamp(0, categories.length - 1)];
          setState(() {
            _selectedCategory = category;
            _tvShowingCategories = false;
            _tvFocusedChannelIndex = 0;
          });
          _searchController.clear();
          _searchQuery = '';
          _showTvChannels(index: 0);
        }
      } else if (channels.isNotEmpty) {
        final index = _tvFocusedChannelIndex.clamp(0, channels.length - 1).toInt();
        _playChannel(channels[index]);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_tvSidebarVisible && !_tvShowingCategories) {
        setState(() => _tvEpgVisible = false);
        _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, categories.length - 1).toInt());
      } else if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
      } else {
        // Hidden sidebar: ignore Left. Do not alter channel or player controls.
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
      } else if (_tvSidebarVisible) {
        // Right toggles the 3-day guide beside the channel rail. It does not
        // change the playing channel, so guide browsing cannot interrupt video.
        setState(() => _tvEpgVisible = !_tvEpgVisible);
      } else {
        // Hidden sidebar: ignore Right as well; Enter is the only opener.
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
      if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
        return KeyEventResult.handled;
      }
      if (_tvSidebarVisible) {
        setState(() { _tvSidebarVisible = false; _tvEpgVisible = false; });
        FocusManager.instance.primaryFocus?.unfocus();
        _focusTvPlayer();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleChannelTileKey(FocusNode node, KeyEvent event, int index) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final channels = _visibleChannels;

    // A tile can retain focus after the overlay is hidden. Never allow that
    // stale tile focus to select/zap a channel while the sidebar is invisible.
    // Enter's first action in this state is ONLY to reopen the sidebar.
    if (!_tvSidebarVisible) {
      if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
        _showTvChannels(index: _tvFocusedChannelIndex);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      if (key == LogicalKeyboardKey.arrowUp && index == 0) {
        _tvSearchFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      _focusTvChannel((index + delta).clamp(0, channels.length - 1).toInt());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
      if (index >= 0 && index < channels.length) _playChannel(channels[index]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      return _handleRemoteKey(node, event);
    }
    return KeyEventResult.ignored;
  }

  // Android TV keeps the video edge-to-edge. The channel rail is an overlay,
  // so showing it never shrinks the player; selecting/zapping hides it immediately.
  Widget _buildTvLayout(List<Channel> channels) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: Focus(
              focusNode: _tvPlayerFocusNode,
              onKeyEvent: _handleRemoteKey,
              child: _buildPlayer(fullscreen: true),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          left: _tvSidebarVisible ? 0 : -330,
          width: 310,
          child: IgnorePointer(
            ignoring: !_tvSidebarVisible,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 100),
              opacity: _tvSidebarVisible ? 1 : 0,
              child: RepaintBoundary(
                child: ClipRect(
                // A translucent panel is cheaper to render than a live blur
                // on lower-powered TV boxes while keeping video visible.
                child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xE6101020),
                      border: Border(
                        right: BorderSide(color: Colors.white.withOpacity(0.12)),
                      ),
                    ),
                    child: SafeArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(18, 12, 12, 8),
                            child: Row(
                              children: [
                                Icon(Icons.blur_on, color: accentColor, size: 26),
                                SizedBox(width: 8),
                                Expanded(child: Text('ANANTA OTT', style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                  fontSize: 16,
                                ))),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                            child: TextField(
                              focusNode: _tvSearchFocusNode,
                              controller: _searchController,
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) {
                                FocusScope.of(context).unfocus();
                                if (_visibleChannels.isNotEmpty) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  _showTvChannels(index: 0);
                                }
                              },
                              onChanged: (value) {
                                setState(() {
                                  _searchQuery = value;
                                  _tvFocusedChannelIndex = 0;
                                  _tvShowingCategories = false;
                                });
                              },
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: 'Search channels',
                                prefixIcon: const Icon(Icons.search, size: 20),
                                suffixIcon: _searchQuery.isEmpty ? null : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                      _tvFocusedChannelIndex = 0;
                                    });
                                  },
                                  icon: const Icon(Icons.clear, size: 18),
                                ),
                                filled: true,
                                fillColor: Colors.white.withOpacity(0.07),
                                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: accentColor, width: 1.5),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Row(
                              children: [
                                Expanded(child: Text(_tvShowingCategories ? 'CATEGORIES' : 'CHANNELS', style: const TextStyle(
                                  color: Colors.white70, fontSize: 11,
                                  fontWeight: FontWeight.bold, letterSpacing: 1.2,
                                ))),
                                Text(_tvShowingCategories ? '${_categories.length}' : '${channels.length}', style: const TextStyle(
                                  color: Colors.white54, fontSize: 11,
                                )),
                                IconButton(
                                  tooltip: _tvShowingCategories ? 'Show channels' : 'Browse categories',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    if (_tvShowingCategories) { _showTvChannels(index: _tvFocusedChannelIndex); }
                                    else { _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, _categories.length - 1).toInt()); }
                                  },
                                  icon: Icon(_tvShowingCategories ? Icons.live_tv : Icons.category_outlined, color: accentColor, size: 19),
                                ),
                                IconButton(
                                  tooltip: _showFavoritesOnly ? 'Show all channels' : 'Show favorites',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
                                  icon: Icon(_showFavoritesOnly ? Icons.favorite : Icons.favorite_border,
                                    color: _showFavoritesOnly ? Colors.pinkAccent : Colors.white70, size: 19),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: _tvShowingCategories
                                ? ListView.builder(
                                    controller: _tvCategoryScrollController,
                                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                                    itemCount: _categories.length,
                                    itemExtent: 58,
                                    itemBuilder: (context, index) {
                                      final category = _categories[index];
                                      final focused = index == _tvFocusedCategoryIndex;
                                      final selected = category == _selectedCategory;
                                      final count = category == 'All'
                                          ? _channels.length
                                          : _channels.where((c) => c.group == category).length;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 100),
                                          decoration: BoxDecoration(
                                            color: focused ? accentColor.withOpacity(0.34) : Colors.white.withOpacity(0.045),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: focused ? accentColor : (selected ? accentColor.withOpacity(0.55) : Colors.white.withOpacity(0.08)), width: focused ? 2 : 1),
                                          ),
                                          child: ListTile(
                                            dense: true,
                                            leading: Icon(category == 'All' ? Icons.apps_rounded : Icons.folder_outlined, color: selected ? accentColor : Colors.white70, size: 20),
                                            title: Text(category, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                                            trailing: Text('$count', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                            onTap: () {
                                              setState(() {
                                                _selectedCategory = category;
                                                _tvFocusedCategoryIndex = index;
                                                _tvShowingCategories = false;
                                                _tvFocusedChannelIndex = 0;
                                              });
                                              _searchController.clear();
                                              _searchQuery = '';
                                              _showTvChannels(index: 0);
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  )
                                : channels.isEmpty
                                    ? const Center(child: Text('No channels found', style: TextStyle(color: Colors.white60)))
                                    : ListView.builder(
                                        controller: _tvChannelScrollController,
                                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                                        itemCount: channels.length,
                                        itemExtent: 96,
                                        itemBuilder: (context, index) => _buildTvChannelTile(channels[index], index),
                                      ),
                          ),
                        ],
                      ),
                    ),
                ),
              ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          left: (_tvSidebarVisible && _tvEpgVisible && !_tvShowingCategories) ? 310 : -360,
          width: 350,
          // Guide is an overlay beside the rail; it never resizes the video.
          child: IgnorePointer(
            ignoring: !_tvSidebarVisible || !_tvEpgVisible || _tvShowingCategories,
            child: AnimatedOpacity(
            duration: const Duration(milliseconds: 90),
            opacity: _tvSidebarVisible && _tvEpgVisible && !_tvShowingCategories ? 1 : 0,
            child: Builder(builder: (context) {
              final preview = _tvEpgPreviewChannel(channels);
              return preview == null ? const SizedBox.shrink() : _buildTvEpgPanel(preview);
            }),
          ),
          ),
        ),
      ],
    );
  }

  Widget _buildTvChannelTile(Channel channel, int index) {
    final selected = _selectedChannel?.url == channel.url;
    final favorite = _favorites.contains(channel.url);
    final focusNode = _tvChannelFocusNodes.putIfAbsent(
      channel.url, () => FocusNode(debugLabel: 'channel-${channel.name}'),
    );
    final focusedByIndex = index == _tvFocusedChannelIndex;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      child: Focus(
        focusNode: focusNode,
        autofocus: focusedByIndex,
        onFocusChange: (hasFocus) {
          if (hasFocus && mounted && _tvFocusedChannelIndex != index) {
            setState(() => _tvFocusedChannelIndex = index);
          }
        },
        onKeyEvent: (node, event) => _handleChannelTileKey(node, event, index),
        child: Builder(builder: (context) {
          final focused = Focus.of(context).hasFocus || focusedByIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: focused
                  ? accentColor.withOpacity(0.34)
                  : selected ? Colors.white.withOpacity(0.13) : Colors.white.withOpacity(0.035),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: focused ? accentColor : (selected ? accentColor.withOpacity(0.6) : Colors.white.withOpacity(0.07)),
                width: focused ? 2 : 1,
              ),
            ),
            child: ListTile(
              focusColor: accentColor.withOpacity(0.22),
              hoverColor: accentColor.withOpacity(0.16),
              dense: false,
              minVerticalPadding: 5,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: accentColor.withOpacity(0.16),
                backgroundImage: _logoForChannel(channel).isNotEmpty ? CachedNetworkImageProvider(_logoForChannel(channel)) : null,
                child: _logoForChannel(channel).isEmpty ? const Icon(Icons.live_tv, color: accentColor, size: 18) : null,
              ),
              title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_epgLabel(channel), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _epgForChannel(channel) == null ? Colors.white38 : const Color(0xFFC9BEFF), fontSize: 10, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(
                    value: _epgProgress(_epgForChannel(channel)), minHeight: 3,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(accentColor),
                  )),
                  const SizedBox(height: 3),
                  Text(channel.group, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
                ],
              ),
              trailing: Icon(favorite ? Icons.favorite : Icons.chevron_right,
                color: favorite ? Colors.pinkAccent : Colors.white38, size: 18),
              onTap: () => _playChannel(channel),
            ),
          );
        }),
      ),
    );
  }

  // --------------------------------------------------
  // GLASS EFFECT
  // --------------------------------------------------
  Widget _glass({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(10),
    double radius = 16,
    Color color = glassColor,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      // Keep the glass appearance with alpha compositing instead of a costly
      // per-card blur; this is significantly lighter on Mi Box hardware.
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color.withOpacity(0.82),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
        ),
        child: child,
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
      setState(() {
        _favorites =
            (prefs.getStringList('ananta_favorites') ?? []).toSet();
      });
    } catch (e) {
      debugPrint('Favorites error: $e');
    }
  }

  Future<void> _saveFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'ananta_favorites',
        _favorites.toList(),
      );
    } catch (e) {
      debugPrint('Saving favorites failed: $e');
    }
  }

  Future<void> _toggleFavorite(Channel channel) async {
    setState(() {
      if (_favorites.contains(channel.url)) {
        _favorites.remove(channel.url);
      } else {
        _favorites.add(channel.url);
      }
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
    String tvgId = '';
    String tvgName = '';
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        final comma = line.lastIndexOf(',');
        name = comma >= 0
            ? line.substring(comma + 1).trim()
            : 'Unknown channel';
        group = _attribute(line, 'group-title');
        logo = _attribute(line, 'tvg-logo');
        tvgId = _attribute(line, 'tvg-id');
        tvgName = _attribute(line, 'tvg-name');
        if (group.isEmpty) group = 'Live TV';
      } else if (!line.startsWith('#') && name != null) {
        final uri = Uri.tryParse(line);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty) {
          result.add(
            Channel(
              name: name,
              url: line,
              group: group,
              logo: logo,
              tvgId: tvgId,
              tvgName: tvgName,
            ),
          );
        }
        name = null;
        group = 'Live TV';
        logo = '';
        tvgId = '';
        tvgName = '';
      }
    }
    return result;
  }

  // --------------------------------------------------
  // EPG / XMLTV
  // --------------------------------------------------
  String _normalizeEpgName(String value) {
    var name = value.toLowerCase().trim();
    name = name.replaceAll(RegExp(r'\b(hd|fhd|uhd|4k|sd|hevc|h265|live|tv)\b', caseSensitive: false), ' ');
    return name.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  Future<void> _initializeEpg() async {
    // Always show the on-device guide first. Only fetch on startup when the
    // cache is absent/expired; a cache younger than two hours is never fetched
    // again just because the app was reopened.
    final cacheIsFresh = await _loadCachedEpg();
    if (!mounted) return;
    if (!cacheIsFresh) unawaited(_loadEpg());
  }

  Map<String, dynamic> _epgMapToJson(Map<String, List<EpgProgram>> source) => {
    for (final entry in source.entries)
      entry.key: entry.value.map((program) => <String, dynamic>{
        'title': program.title,
        'description': program.description,
        'start': program.start.millisecondsSinceEpoch,
        'stop': program.stop.millisecondsSinceEpoch,
      }).toList(),
  };

  Map<String, List<EpgProgram>> _epgMapFromJson(dynamic raw) {
    final result = <String, List<EpgProgram>>{};
    if (raw is! Map) return result;
    // Keep a rolling three-day guide on device: programmes that have ended
    // are discarded, while the current and next three days remain available.
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(const Duration(hours: 6));
    final horizon = now.add(const Duration(days: 3));
    for (final entry in raw.entries) {
      if (entry.value is! List) continue;
      final list = <EpgProgram>[];
      for (final item in entry.value as List) {
        if (item is! Map) continue;
        try {
          final start = DateTime.fromMillisecondsSinceEpoch(item['start'] as int, isUtc: true);
          final stop = DateTime.fromMillisecondsSinceEpoch(item['stop'] as int, isUtc: true);
          if (!stop.isAfter(cutoff) || start.isAfter(horizon)) continue;
          list.add(EpgProgram(
            title: item['title']?.toString() ?? '',
            description: item['description']?.toString() ?? '',
            start: start,
            stop: stop,
          ));
        } catch (_) {}
      }
      list.sort((a, b) => a.start.compareTo(b.start));
      if (list.isNotEmpty) result[entry.key.toString()] = list;
    }
    return result;
  }

  Future<bool> _loadCachedEpg() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('ananta_epg_3day_cache_v1');
      if (cached == null || cached.isEmpty) return false;
      final decoded = jsonDecode(cached);
      if (decoded is! Map) return false;
      final savedAtRaw = decoded['savedAt'];
      final savedAt = savedAtRaw is int ? savedAtRaw : 0;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      final cacheIsFresh = savedAt > 0 && age >= 0 &&
          age < const Duration(hours: 2).inMilliseconds;
      final byId = _epgMapFromJson(decoded['byId']);
      final byName = _epgMapFromJson(decoded['byName']);
      final rawLogosById = decoded['logosById'];
      final logosById = rawLogosById is Map ? rawLogosById.map<String, String>((k, v) => MapEntry(k.toString(), v.toString())) : <String, String>{};
      final rawLogosByName = decoded['logosByName'];
      final logosByName = rawLogosByName is Map ? rawLogosByName.map<String, String>((k, v) => MapEntry(k.toString(), v.toString())) : <String, String>{};
      if (!mounted || (byId.isEmpty && byName.isEmpty && logosById.isEmpty)) return false;
      setState(() {
        _epgById = byId;
        _epgByName = byName;
        _epgLogosById = logosById;
        _epgLogosByName = logosByName;
        _epgStatus = cacheIsFresh
            ? 'Using saved programme guide'
            : 'Using saved guide; refresh pending';
        _rebuildEpgChannelIndex();
      });
      return cacheIsFresh;
    } catch (error) {
      debugPrint('Cached EPG could not be loaded: $error');
      return false;
    }
  }

  Future<void> _saveCachedEpg(
    Map<String, List<EpgProgram>> byId,
    Map<String, List<EpgProgram>> byName,
    Map<String, String> logosById,
    Map<String, String> logosByName,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ananta_epg_3day_cache_v1', jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'byId': _epgMapToJson(byId),
        'byName': _epgMapToJson(byName),
        'logosById': logosById,
        'logosByName': logosByName,
      }));
    } catch (error) {
      debugPrint('Cached EPG could not be saved: $error');
    }
  }

  Future<void> _loadEpg() async {
    if (_epgLoading) return;
    _epgLoading = true;
    try {
    final candidatesById = <String, List<EpgProgram>>{};
    // Hash sets avoid quadratic list scans when EPG feeds contain overlapping
    // programmes from multiple providers. This is important on low-memory TV boxes.
    final seenProgramsById = <String, Set<String>>{};
    final namesById = <String, List<String>>{};
    final logosById = <String, String>{};
    final logosByName = <String, String>{};
    var successfulSources = 0;
    for (final source in epgSourceUrls) {
      try {
        final response = await http.get(Uri.parse(source), headers: const {
          'User-Agent': 'AnantaOTT/1.0',
          'Accept': '*/*',
          'Accept-Encoding': 'gzip',
        }).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) continue;
        final parsed = await compute(_parseEpgPayload, response.bodyBytes);
        final sourceNames = (parsed['namesById'] as Map).map<String, List<String>>(
          (key, value) => MapEntry(key.toString(), (value as List).map((item) => item.toString()).toList()),
        );
        for (final entry in sourceNames.entries) {
          final existing = namesById.putIfAbsent(entry.key, () => <String>[]);
          for (final name in entry.value) {
            if (!existing.contains(name)) existing.add(name);
          }
        }
        final rawSourceLogos = parsed['logosById'];
        if (rawSourceLogos is Map) {
          for (final entry in rawSourceLogos.entries) {
            final url = entry.value.toString();
            if (url.startsWith('http://') || url.startsWith('https://')) logosById.putIfAbsent(entry.key.toString(), () => url);
          }
        }
        for (final entry in sourceNames.entries) {
          final logo = logosById[entry.key];
          if (logo != null) {
            for (final name in entry.value) logosByName.putIfAbsent(_normalizeEpgName(name), () => logo);
          }
        }
        final sourcePrograms = parsed['programmes'] as List;
        for (final raw in sourcePrograms) {
          final item = raw as Map;
          final id = item['id'].toString();
          final program = EpgProgram(
            title: item['title'].toString(),
            // Long descriptions bloat SharedPreferences and can stall low-RAM TVs.
            description: (item['description']?.toString() ?? '').substring(0, (item['description']?.toString() ?? '').length.clamp(0, 400).toInt()),
            start: DateTime.fromMillisecondsSinceEpoch(item['start'] as int, isUtc: true),
            stop: DateTime.fromMillisecondsSinceEpoch(item['stop'] as int, isUtc: true),
          );
          final list = candidatesById.putIfAbsent(id, () => <EpgProgram>[]);
          final key = '${program.start.millisecondsSinceEpoch}|${program.title}';
          final seen = seenProgramsById.putIfAbsent(id, () => <String>{});
          if (seen.add(key)) list.add(program);
        }
        successfulSources++;
      } catch (error) {
        debugPrint('EPG source failed ($source): $error');
      }
    }

    final byId = <String, List<EpgProgram>>{};
    final byName = <String, List<EpgProgram>>{};
    final seenProgramsByName = <String, Set<String>>{};
    final epgNow = DateTime.now().toUtc();
    final keepAfter = epgNow.subtract(const Duration(hours: 6));
    final keepUntil = epgNow.add(const Duration(days: 3));
    for (final entry in candidatesById.entries) {
      final programs = entry.value
        .where((p) => p.stop.isAfter(keepAfter) && p.start.isBefore(keepUntil))
        .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      if (programs.isNotEmpty) byId[entry.key] = programs;
      for (final name in namesById[entry.key] ?? const <String>[]) {
        final normalized = _normalizeEpgName(name);
        if (normalized.isEmpty || programs.isEmpty) continue;
        final list = byName.putIfAbsent(normalized, () => <EpgProgram>[]);
        final seen = seenProgramsByName.putIfAbsent(normalized, () => <String>{});
        for (final program in programs) {
          final key = '${program.start.millisecondsSinceEpoch}|${program.title}';
          if (seen.add(key)) list.add(program);
        }
      }
    }
    for (final list in byName.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    if (!mounted) return;
    if (byId.isNotEmpty || byName.isNotEmpty) {
      await _saveCachedEpg(byId, byName, logosById, logosByName);
    }
    if (!mounted) return;
    setState(() {
      if (byId.isNotEmpty || byName.isNotEmpty) {
        _epgById = byId;
        _epgByName = byName;
        _epgLogosById = logosById;
        _epgLogosByName = logosByName;
        _epgStatus = 'Guide loaded from $successfulSources source(s)';
      } else if (_epgById.isEmpty && _epgByName.isEmpty) {
        _epgStatus = 'Programme guide unavailable';
      }
      _rebuildEpgChannelIndex();
    });
    debugPrint('EPG loaded: ${byId.length} channel IDs, ${byName.length} names from $successfulSources sources');
    } finally {
      _epgLoading = false;
    }
  }

  EpgProgram? _pickCurrentProgram(List<EpgProgram>? programs) {
    if (programs == null || programs.isEmpty) return null;
    final now = DateTime.now().toUtc();
    for (final program in programs) {
      if (program.isAiringAt(now)) return program;
    }
    for (final program in programs) {
      if (program.start.isAfter(now)) return program;
    }
    return null;
  }

  List<EpgProgram> _resolveEpgCandidates(Channel channel) {
    final id = channel.tvgId.trim();
    if (id.isNotEmpty) {
      final direct = _epgById[id];
      if (direct != null && direct.isNotEmpty) return direct;
      final normalizedId = _normalizeEpgName(id);
      for (final entry in _epgById.entries) {
        if (_normalizeEpgName(entry.key) == normalizedId) return entry.value;
      }
    }
    final playlistName = _normalizeEpgName(channel.tvgName);
    if (playlistName.isNotEmpty) {
      final playlistNameMatch = _epgByName[playlistName];
      if (playlistNameMatch != null && playlistNameMatch.isNotEmpty) return playlistNameMatch;
    }
    final name = _normalizeEpgName(channel.name);
    final directName = _epgByName[name];
    if (directName != null && directName.isNotEmpty) return directName;
    if (name.length >= 5) {
      for (final entry in _epgByName.entries) {
        if (entry.key.length >= 5 && (entry.key.contains(name) || name.contains(entry.key))) return entry.value;
      }
    }
    return const <EpgProgram>[];
  }

  void _rebuildEpgChannelIndex() {
    _epgByChannelUrl = <String, List<EpgProgram>>{
      for (final channel in _channels) channel.url: _resolveEpgCandidates(channel),
    };
  }

  EpgProgram? _epgForChannel(Channel channel) =>
      _pickCurrentProgram(_epgByChannelUrl[channel.url] ?? _resolveEpgCandidates(channel));

  String _logoForChannel(Channel channel) {
    if (channel.logo.trim().isNotEmpty) return channel.logo.trim();
    final id = channel.tvgId.trim();
    if (id.isNotEmpty && _epgLogosById[id] != null) return _epgLogosById[id]!;
    final names = <String>[channel.tvgName, channel.name];
    for (final name in names) {
      final logo = _epgLogosByName[_normalizeEpgName(name)];
      if (logo != null && logo.isNotEmpty) return logo;
    }
    return '';
  }

  double _epgProgress(EpgProgram? program) {
    if (program == null || !program.stop.isAfter(program.start)) return 0;
    final now = DateTime.now().toUtc();
    return (now.difference(program.start).inMilliseconds / program.stop.difference(program.start).inMilliseconds).clamp(0.0, 1.0).toDouble();
  }

  List<EpgProgram> _epgScheduleForChannel(Channel channel) {
    final source = _epgByChannelUrl[channel.url] ?? _resolveEpgCandidates(channel);
    final now = DateTime.now().toUtc();
    final start = now.subtract(const Duration(days: 3));
    final end = now.add(const Duration(days: 3));
    return source.where((p) => p.stop.isAfter(start) && p.start.isBefore(end)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  Channel? _tvEpgPreviewChannel(List<Channel> channels) {
    if (_tvShowingCategories) return _selectedChannel;
    if (channels.isEmpty) return _selectedChannel;
    final index = _tvFocusedChannelIndex.clamp(0, channels.length - 1).toInt();
    return channels[index];
  }

  String _formatEpgTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _buildTvEpgPanel(Channel channel) {
    final schedule = _epgScheduleForChannel(channel);
    final now = DateTime.now().toUtc();
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xE6101020),
        border: Border(right: BorderSide(color: Colors.white.withOpacity(0.10))),
      ),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('3-DAY TV GUIDE', style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: Color(0xFFC9BEFF), fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(channel.name.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Text(channel.group, style: const TextStyle(fontSize: 11, color: Colors.white60)),
            ]),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: schedule.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_epgStatus == 'Loading programme guide…' ? 'Loading guide…' : 'No 3-day guide available for this channel', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 12))))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  itemCount: schedule.length,
                  itemBuilder: (context, index) {
                    final program = schedule[index];
                    final current = program.isAiringAt(now);
                    final previous = index == 0 ? null : schedule[index - 1];
                    final newDay = previous == null || previous.start.toLocal().year != program.start.toLocal().year || previous.start.toLocal().month != program.start.toLocal().month || previous.start.toLocal().day != program.start.toLocal().day;
                    final localStart = program.start.toLocal();
                    final dayLabel = '${['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][localStart.weekday - 1]}, ${localStart.day.toString().padLeft(2, '0')}/${localStart.month.toString().padLeft(2, '0')}';
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (newDay) Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 5), child: Text(dayLabel, style: const TextStyle(color: Color(0xFFC9BEFF), fontSize: 11, fontWeight: FontWeight.bold))),
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: current ? accentColor.withOpacity(0.22) : Colors.white.withOpacity(0.045),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: current ? accentColor.withOpacity(0.75) : Colors.white.withOpacity(0.07)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(_formatEpgTime(program.start), style: const TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                            const Spacer(),
                            if (current) const Text('NOW', style: TextStyle(fontSize: 9, color: Color(0xFFD6CCFF), fontWeight: FontWeight.bold, letterSpacing: 1)),
                          ]),
                          const SizedBox(height: 4),
                          Text(program.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: current ? FontWeight.bold : FontWeight.w500)),
                          if (program.description.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(program.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white60, height: 1.2)),
                          ],
                          if (current) ...[
                            const SizedBox(height: 7),
                            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
                              value: program.stop.isAfter(program.start) ? (now.difference(program.start).inMilliseconds / program.stop.difference(program.start).inMilliseconds).clamp(0.0, 1.0).toDouble() : 0.0,
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation<Color>(accentColor),
                            )),
                          ],
                        ]),
                      ),
                    ]);
                  },
                ),
          ),
        ]),
      ),
    );
  }

  String _epgLabel(Channel channel) {
    final program = _epgForChannel(channel);
    if (program == null) {
      return _epgStatus == 'Loading programme guide…' ? 'Loading programme info…' : 'Programme info unavailable';
    }
    final prefix = program.isAiringAt(DateTime.now().toUtc()) ? 'NOW' : 'UP NEXT';
    return '$prefix · ${program.title}';
  }

  // --------------------------------------------------
  // PLAYLIST REFRESH
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
      final query = Map<String, String>.from(
        baseUri.queryParameters,
      );
      query['_refresh'] =
          DateTime.now().millisecondsSinceEpoch.toString();
      final uri = baseUri.replace(queryParameters: query);
      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent': 'AnantaOTT/1.0',
              'Accept': '*/*',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception(
          'Playlist server returned HTTP ${response.statusCode}',
        );
      }
      final parsed = _parseM3u(response.body);
      if (parsed.isEmpty) {
        throw Exception('No valid channels found in the M3U file.');
      }
      final updated = <Channel>[ptvChannel];
      final seen = <String>{ptvChannel.url};
      for (final channel in parsed) {
        if (seen.add(channel.url)) {
          updated.add(channel);
        }
      }
      if (!mounted || requestId != _playlistRequestId) return;
      final groups = updated.map((c) => c.group).toSet();
      setState(() {
        _channels = updated;
        if (_selectedCategory != 'All' &&
            !groups.contains(_selectedCategory)) {
          _selectedCategory = 'All';
        }
        _status = '${updated.length} channels loaded';
        _rebuildEpgChannelIndex();
      });
    } catch (e) {
      debugPrint('Playlist refresh error: $e');
      if (!mounted || requestId != _playlistRequestId) return;
      setState(() {
        _status = 'Refresh failed; existing channels retained';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playlist refresh failed: $e'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: _loadPlaylist,
          ),
        ),
      );
    } finally {
      if (mounted && requestId == _playlistRequestId) {
        setState(() => _loadingPlaylist = false);
      }
    }
  }

  // --------------------------------------------------
  // PLAYER CONTROLS AUTO-HIDE
  // --------------------------------------------------
  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(
      const Duration(seconds: 2),
      () {
        if (!mounted) return;
        if (_player?.value.isInitialized == true) {
          setState(() {
            _controlsVisible = false;
          });
        }
      },
    );
  }

  void _showPlayerControls() {
    if (!mounted) return;
    setState(() {
      _controlsVisible = true;
    });
    if (_player?.value.isInitialized == true) {
      _scheduleControlsHide();
    }
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
    if (!mounted) return;
    // Every selection supersedes the previous pending request. Do not block
    // channel changes while a stream is buffering, and keep the current player
    // alive until a replacement stream is actually ready.
    if (_selectedChannel?.url == channel.url && _player?.value.isInitialized == true) {
      // Choosing the currently playing channel cancels any other stream that
      // is still buffering instead of leaving a stale request running.
      ++_playRequestId;
      final pending = _pendingPlayer;
      _pendingPlayer = null;
      if (pending != null) { try { await pending.dispose(); } catch (_) {} }
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _tvSidebarVisible = false;
        _tvEpgVisible = false;
      });
      _focusTvPlayer();
      return;
    }
    final requestId = ++_playRequestId;
    final oldPlayer = _player;
    final previousPending = _pendingPlayer;
    _pendingPlayer = null;
    if (previousPending != null) {
      try { await previousPending.dispose(); } catch (_) {}
    }
    // Release the previous native decoder before creating another one. TV
    // boxes often have very limited hardware decoder slots; retaining two
    // ExoPlayer instances is a common cause of decoder errors and force-closes.
    if (oldPlayer != null) {
      if (mounted) setState(() { _player = null; });
      try { await oldPlayer.dispose(); } catch (_) {}
    }
    if (!mounted || requestId != _playRequestId) return;
    _controlsTimer?.cancel();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(channel.url),
      httpHeaders: const {
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
    );
    _pendingPlayer = controller;
    setState(() {
      // Keep the sidebar open during buffering so another channel can be
      // selected immediately. Only one native video controller is kept alive
      // to reduce decoder exhaustion on low-memory Android TV boxes.
      _playerError = null;
      _connecting = true;
      _controlsVisible = true;
      _status = 'Buffering ${channel.name}...';
    });
    try {
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      if (controller.value.hasError) {
        throw Exception(
          controller.value.errorDescription ?? 'Player error',
        );
      }

      // Explicitly set audible playback. Some TV builds can retain a muted
      // volume state across controller replacements; unsupported stream codecs
      // still depend on the device's native decoder.
      await controller.setVolume(1.0);
      // Commit the channel only after its stream initializes successfully.
      await controller.play();
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      _pendingPlayer = null;
      setState(() {
        _player = controller;
        _selectedChannel = channel;
        _status = 'Playing ${channel.name}';
        _connecting = false;
        _tvSidebarVisible = false;
        _tvEpgVisible = false;
      });
      _focusTvPlayer();
      if (oldPlayer != null && oldPlayer != controller) {
        try { await oldPlayer.dispose(); } catch (_) {}
      }
      await WakelockPlus.enable();
      _scheduleControlsHide();
    } on TimeoutException {
      try { await controller.dispose(); } catch (_) {}
      if (!mounted || requestId != _playRequestId) return;
      _pendingPlayer = null;
      setState(() {
        _playerError = 'Stream timed out. Choose another channel.';
        _status = 'Stream timed out';
        _connecting = false;
      });
    } catch (e) {
      debugPrint('Playback error for ${channel.url}: $e');
      try { await controller.dispose(); } catch (_) {}
      if (!mounted || requestId != _playRequestId) return;
      _pendingPlayer = null;
      setState(() {
        _playerError = 'Unable to play this stream. Try another channel.';
        _status = 'Playback failed';
        _connecting = false;
      });
    }

  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    try {
      if (player.value.isPlaying) {
        await player.pause();
        await WakelockPlus.disable();
      } else {
        await player.play();
        await WakelockPlus.enable();
      }
      if (!mounted) return;
      setState(() {});
      _showPlayerControls();
    } catch (e) {
      debugPrint('Playback control error: $e');
    }
  }

  Future<void> _changeChannel(int direction) async {
    final list = _visibleChannels;
    if (list.isEmpty) return;
    final currentIndex = list.indexWhere(
      (channel) => channel.url == _selectedChannel?.url,
    );
    final nextIndex = currentIndex == -1
        ? (direction > 0 ? 0 : list.length - 1)
        : (currentIndex + direction + list.length) % list.length;
    await _playChannel(list[nextIndex]);
  }

  // --------------------------------------------------
  // FULLSCREEN - FIXED: Horizontal only when entering, vertical only when exiting
  // --------------------------------------------------
  Future<void> _setFullscreen(bool value) async {
    if (value) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      // Restore sensor/system orientation rather than locking every phone to portrait.
      // Android TV devices can remain in their normal landscape orientation.
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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

    final media = MediaQuery.maybeOf(context);
    final tvMode = media != null &&
        media.size.width >= 850 &&
        media.size.width > media.size.height;

    if (tvMode && _tvSidebarVisible) {
      // First BACK closes the channel rail. A subsequent BACK is allowed to
      // leave the app instead of reopening/toggling the rail forever.
      setState(() { _tvSidebarVisible = false; _tvEpgVisible = false; });
      FocusManager.instance.primaryFocus?.unfocus();
      _focusTvPlayer();
      return false;
    }

    // Let Android handle BACK when the TV sidebar is already hidden.
    return true;
  }

  // --------------------------------------------------
  // CATEGORY FILTERS
  // --------------------------------------------------
  List<String> get _categories {
    final groups = _channels
        .map((channel) => channel.group.trim())
        .where((group) => group.isNotEmpty)
        .toSet()
        .toList();
    groups.sort(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    return ['All', ...groups];
  }

  List<Channel> get _visibleChannels {
    final query = _searchQuery.trim().toLowerCase();
    return _channels.where((channel) {
      final matchesCategory = _selectedCategory == 'All' ||
          channel.group == _selectedCategory;
      final matchesSearch =
          channel.name.toLowerCase().contains(query) ||
          channel.group.toLowerCase().contains(query);
      final matchesFavorite = !_showFavoritesOnly ||
          _favorites.contains(channel.url);
      return matchesCategory && matchesSearch && matchesFavorite;
    }).toList();
  }

  // --------------------------------------------------
  // PLAYER UI
  // --------------------------------------------------
  Widget _buildPlayer({required bool fullscreen}) {
    final media = MediaQuery.of(context);
    final tvMode = media.size.width >= 850 && media.size.width > media.size.height;
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
                  aspectRatio: player!.value.aspectRatio > 0
                      ? player.value.aspectRatio
                      : 16 / 9,
                  child: VideoPlayer(player),
                ),
              )
            else
              Center(
                child: _connecting
                    ? const CircularProgressIndicator(
                        color: accentColor,
                      )
                    : Icon(
                        _playerError == null
                            ? Icons.live_tv
                            : Icons.error_outline,
                        size: 48,
                        color: _playerError == null
                            ? accentColor
                            : Colors.redAccent,
                      ),
              ),
            // All controls disappear together after 2 seconds.
            if (_controlsVisible) ...[
              if (!tvMode)
                Positioned(
                top: 8,
                left: 10,
                right: 10,
                child: _glass(
                  radius: 12,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.circle,
                        size: 8,
                        color: Colors.redAccent,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          _selectedChannel?.name ?? appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (!tvMode)
                        IconButton(
                          tooltip: 'Fullscreen',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 34,
                            minHeight: 34,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => _setFullscreen(!_fullscreen),
                          icon: Icon(
                            _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                            size: 21,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (initialized)
                Center(
                  child: _glass(
                    radius: 28,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Previous channel',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => _changeChannel(-1),
                          icon: const Icon(
                            Icons.skip_previous_rounded,
                            size: 23,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Play or pause',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: _togglePlayback,
                          icon: Icon(
                            player!.value.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            size: 30,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Next channel',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => _changeChannel(1),
                          icon: const Icon(
                            Icons.skip_next_rounded,
                            size: 23,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (tvMode && _selectedChannel != null)
                Positioned(
                  bottom: initialized ? 64 : 12,
                  left: 18,
                  right: 18,
                  child: IgnorePointer(
                    child: _glass(
                      radius: 14,
                      color: const Color(0xB5101020),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: accentColor.withOpacity(0.45)),
                            ),
                            child: _logoForChannel(_selectedChannel!).isNotEmpty
                                ? ClipRRect(borderRadius: BorderRadius.circular(10), child: CachedNetworkImage(imageUrl: _logoForChannel(_selectedChannel!), fit: BoxFit.cover, placeholder: (_, __) => const Icon(Icons.live_tv, color: accentColor), errorWidget: (_, __, ___) => const Icon(Icons.live_tv, color: accentColor)))
                                : const Icon(Icons.live_tv, color: accentColor, size: 23),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_selectedChannel!.name.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text('NOW · ${_epgForChannel(_selectedChannel!)?.title ?? 'Programme info unavailable'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFFD2C8FF), fontWeight: FontWeight.w600)),
                                const SizedBox(height: 4),
                                ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: _epgProgress(_epgForChannel(_selectedChannel!)), minHeight: 4, backgroundColor: Colors.white12, valueColor: const AlwaysStoppedAnimation<Color>(accentColor))),
                                const SizedBox(height: 3),
                                Builder(builder: (context) { final schedule = _epgScheduleForChannel(_selectedChannel!); final now = DateTime.now().toUtc(); EpgProgram? next; for (final item in schedule) { if (item.start.isAfter(now)) { next = item; break; } } return Text('NEXT · ${next?.title ?? 'Not available'}${next == null ? '' : ' · ${_formatEpgTime(next.start)}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white70)); }),
                                const SizedBox(height: 3),
                                Text(_selectedChannel!.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white60)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.18), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.redAccent.withOpacity(0.55))),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.circle, color: Colors.redAccent, size: 7), SizedBox(width: 6), Text('LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.1))]),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (initialized)
                Positioned(
                  bottom: 10,
                  left: 18,
                  right: 18,
                  child: _glass(
                    radius: 12,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        const Spacer(),
                        IconButton(
                          tooltip: 'Favorite',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: _selectedChannel == null
                              ? null
                              : () => _toggleFavorite(
                                    _selectedChannel!,
                                  ),
                          icon: Icon(
                            _selectedChannel != null &&
                                    _favorites.contains(
                                      _selectedChannel!.url,
                                    )
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
                    onPressed: _selectedChannel == null
                        ? null
                        : () => _playChannel(_selectedChannel!),
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
  // CATEGORY CHIPS
  // --------------------------------------------------
  Widget _buildCategories() {
    return SizedBox(
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
              fontWeight:
                  selected ? FontWeight.bold : FontWeight.normal,
            ),
            onSelected: (_) {
              setState(() => _selectedCategory = category);
            },
          );
        },
      ),
    );
  }

  // --------------------------------------------------
  // CHANNEL TILE
  // --------------------------------------------------
  Widget _buildChannelTile(Channel channel) {
    final selected = _selectedChannel?.url == channel.url;
    final favorite = _favorites.contains(channel.url);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: _glass(
        radius: 15,
        padding: EdgeInsets.zero,
        color: selected ? const Color(0xFF373052) : glassColor,
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: CircleAvatar(
            radius: 21,
            backgroundColor: accentColor.withOpacity(0.17),
            backgroundImage: _logoForChannel(channel).isNotEmpty ? CachedNetworkImageProvider(_logoForChannel(channel)) : null,
            child: _logoForChannel(channel).isEmpty
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
            onPressed: () => _toggleFavorite(channel),
            icon: Icon(
              favorite ? Icons.favorite : Icons.favorite_border,
              color: favorite ? Colors.pinkAccent : Colors.white54,
              size: 20,
            ),
          ),
          onTap: () => _playChannel(channel),
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
    _epgClock?.cancel();
    _epgRefreshTimer?.cancel();
    _playlistRequestId++;
    _playRequestId++;
    final pendingPlayer = _pendingPlayer;
    _pendingPlayer = null;
    if (pendingPlayer != null) { pendingPlayer.dispose(); }
    _searchController.dispose();
    _tvChannelScrollController.dispose();
    _tvCategoryScrollController.dispose();
    _tvPlayerFocusNode.dispose();
    _tvSearchFocusNode.dispose();
    for (final node in _tvChannelFocusNodes.values) { node.dispose(); }
    _tvChannelFocusNodes.clear();
    _player?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    SystemChrome.setPreferredOrientations(
      DeviceOrientation.values,
    );
    super.dispose();
  }

  // --------------------------------------------------
  // MAIN SCREEN
  // --------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final channels = _visibleChannels;
    final media = MediaQuery.of(context);
    final useTvLayout = !_fullscreen && media.size.width >= 850 && media.size.width > media.size.height;
    return Focus(
      autofocus: true,
      onKeyEvent: _handleRemoteKey,
      child: WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        appBar: (_fullscreen || useTvLayout)
            ? null
            : AppBar(
                backgroundColor: backgroundColor,
                title: const Row(
                  children: [
                    Icon(
                      Icons.blur_on,
                      color: accentColor,
                      size: 29,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Ananta OTT',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'Favorites',
                    onPressed: () {
                      setState(() {
                        _showFavoritesOnly = !_showFavoritesOnly;
                      });
                    },
                    icon: Icon(
                      _showFavoritesOnly
                          ? Icons.favorite
                          : Icons.favorite_border,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh playlist',
                    onPressed:
                        _loadingPlaylist ? null : _loadPlaylist,
                    icon: _loadingPlaylist
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accentColor,
                            ),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
        body: _fullscreen
            ? _buildPlayer(fullscreen: true)
            : useTvLayout
                ? _buildTvLayout(channels)
                : Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF19152B),
                      backgroundColor,
                      Color(0xFF101020),
                    ],
                  ),
                ),
                child: Column(
                  children: [
                    _buildPlayer(fullscreen: false),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        14,
                        12,
                        14,
                        8,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Explore channels',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            '${channels.length} channels',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      child: _glass(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        radius: 15,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) {
                            setState(() => _searchQuery = value);
                          },
                          decoration: InputDecoration(
                            hintText: 'Search channels...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchQuery.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(
                                        () => _searchQuery = '',
                                      );
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
                      padding: const EdgeInsets.fromLTRB(
                        16,
                        8,
                        16,
                        4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: channels.isEmpty
                          ? Center(
                              child: Text(
                                _showFavoritesOnly
                                    ? 'No favorites in this category'
                                    : 'No channels found',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white60,
                                ),
                              ),
                            )
                          : ListView.builder(
                              key: ValueKey(
                                '$_selectedCategory-'
                                '$_showFavoritesOnly-$_searchQuery',
                              ),
                              itemCount: channels.length,
                              itemBuilder: (context, index) {
                                return _buildChannelTile(
                                  channels[index],
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
      ),
      ),
    );
  }
}
