import 'dart:math';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

class PortraitFeedItem {
  PortraitFeedItem({
    required this.bvid,
    this.cid,
    this.aid,
    this.cover,
    this.title,
    this.duration,
    this.dimension,
    this.vertical,
  });

  final String bvid;
  int? cid;
  final int? aid;
  final String? cover;
  final String? title;
  final int? duration;
  Dimension? dimension;

  /// 是否竖屏：true / false 是已有结论，null 表示还没判过、要用 pagelist 探测
  bool? vertical;

  /// 探测失败过几次（网络、风控），失败过的往后排，别一直卡在同一条上
  int probeFails = 0;

  /// 尺寸是否已知（不用再发探测请求）
  bool get isKnown => vertical != null || dimension != null;

  bool get isVertical => vertical ?? (dimension?.isVertical == true);
}

/// 竖屏即刷的取流：
///
/// 官方 App 的首页推荐条目自带「竖屏」标记（rcmd_reason）和 uri 上的
/// player_width / player_height，所以优先吃 App 端推荐池：绝大多数候选不用
/// 发请求就能判出是不是竖屏，候选池里很快就能攒出一堆指定能播的竖屏视频。
/// Web 端推荐池没有这两样，只有拿它补货时才逐条 pagelist 探测。
///
/// 探测是并发的，而且不会「试几条就放弃」：只要候选池里还有货就接着找，只在
/// 真的取空（或到了探测上限）时才返回 null，所以一直上滑不会突然刷不出视频。
class PortraitFeedService {
  PortraitFeedService._();

  static final PortraitFeedService instance = PortraitFeedService._();

  /// 上滑回退栈上限
  static const int _maxHistory = 50;

  /// 候选池上限，长时间挂着也不会无限堆
  static const int _maxQueue = 240;

  /// 一次上滑最多同时探测几条候选
  static const int _probeConcurrency = 6;

  /// 一次上滑最多探测几条候选，超过就把剩下的留给下次上滑
  static const int _maxProbe = 48;

  /// 一次上滑的探测时间预算，超时先返回，下次上滑接着找
  static const Duration _probeBudget = Duration(seconds: 5);

  /// 一次切换最多续取几页推荐（关掉「自动续取推荐」时只取一页）
  static const int _maxPages = 6;

  final List<PortraitFeedItem> _queue = [];
  final List<PortraitFeedItem> _history = [];

  /// 已经确认不是竖屏的 bvid，避免反复回锅探测
  final Set<String> _rejected = <String>{};

  /// 开启「随机视频」后从候选池里随机取，而不是按推荐顺序依次取
  final Random _random = Random();

  String? _cursor;

  /// App 端推荐池的 idx（官方首页推荐，条目自带竖屏标记）
  int _appIdx = 0;

  /// Web 端推荐池的 fresh_idx
  int _webIdx = 0;

  Future<int>? _homeFuture;
  Future<int>? _relatedFuture;

  // 预取的下一个视频与它的锚点 bvid：只在同一个「当前视频」上滑时复用，
  // 锚点变了就丢弃，避免用户绕回来时拿到过期的推荐。
  PortraitFeedItem? _prefetched;
  String? _prefetchedFor;
  String? _prefetchingFor;
  Future<void>? _prefetchFuture;

  String? get cursor => _cursor;

  int get historyLength => _history.length;

  bool get canGoPrevious => _history.isNotEmpty;

  void visit(String bvid) {
    if (_cursor == bvid) {
      return;
    }
    final int index = _history.indexWhere((e) => e.bvid == bvid);
    if (index == -1) {
      _queue.clear();
      _history.clear();
      _dropPrefetch();
    } else {
      _history.removeRange(index, _history.length);
    }
    _cursor = bvid;
  }

  void push(PortraitFeedItem item) {
    if (_history.isNotEmpty && _history.last.bvid == item.bvid) {
      return;
    }
    _history.add(item);
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
  }

  PortraitFeedItem? pop() {
    if (_history.isEmpty) {
      return null;
    }
    _dropPrefetch();
    return _history.removeLast();
  }

  void markCursor(PortraitFeedItem item) => _cursor = item.bvid;

  void clear() {
    _queue.clear();
    _history.clear();
    _rejected.clear();
    _cursor = null;
    _dropPrefetch();
  }

  /// 关闭「竖屏即刷」或换页面时彻底清空，连推荐池的分页游标一起重置，
  /// 下次打开从头开始取推荐
  void reset() {
    clear();
    _appIdx = 0;
    _webIdx = 0;
  }

  /// 后台预取 [currentBvid] 之后的视频：上滑时直接命中缓存，不必等网络和
  /// 竖屏探测。失败静默，真正切换时还会再试一次。
  void preloadNext({required String currentBvid}) {
    if (currentBvid.isEmpty) return;
    if (_prefetchedFor == currentBvid && _prefetched != null) return;
    if (_prefetchingFor == currentBvid && _prefetchFuture != null) return;
    _prefetchingFor = currentBvid;
    late final Future<void> future;
    future = _findNext(currentBvid)
        .then((item) {
          if (item != null && _prefetchedFor != currentBvid) {
            _prefetched = item;
            _prefetchedFor = currentBvid;
          }
        })
        .catchError((Object _) {})
        .whenComplete(() {
          if (identical(_prefetchFuture, future)) {
            _prefetchFuture = null;
            _prefetchingFor = null;
          }
        });
    _prefetchFuture = future;
  }

  PortraitFeedItem? _takePrefetched(String currentBvid) {
    final item = _prefetched;
    final forBvid = _prefetchedFor;
    if (item == null || forBvid != currentBvid) {
      return null;
    }
    _prefetched = null;
    _prefetchedFor = null;
    if (item.bvid == currentBvid ||
        _history.any((e) => e.bvid == item.bvid)) {
      return null;
    }
    return item;
  }

  void _dropPrefetch() {
    _prefetched = null;
    _prefetchedFor = null;
    _prefetchingFor = null;
    _prefetchFuture = null;
  }

  Future<PortraitFeedItem?> next({required String currentBvid}) async {
    final pending = _prefetchFuture;
    if (pending != null && _prefetchingFor == currentBvid) {
      await pending;
    }
    final cached = _takePrefetched(currentBvid);
    if (cached != null) {
      return cached;
    }
    return _findNext(currentBvid);
  }

  Future<PortraitFeedItem?> _findNext(String currentBvid) async {
    // 关掉「自动续取推荐」就只允许取一页，否则一直往后翻，刷不完
    final int maxPages = Pref.portraitNewv ? _maxPages : 1;
    final Stopwatch stopwatch = Stopwatch()..start();
    int probes = 0;
    int pages = 0;
    // 关掉「使用首页推荐」时先用当前视频的相关推荐，用完后自动接首页推荐
    bool relatedFirst = !Pref.portraitRC;
    bool relatedUsed = !Pref.portraitRC;

    while (true) {
      // 池子里已经确认竖屏的，直接给，不用等网络
      final vertical = _takeVertical(currentBvid);
      if (vertical != null) {
        return vertical;
      }

      if (probes < _maxProbe && stopwatch.elapsed < _probeBudget) {
        final batch = _takeUnknown(
          currentBvid,
          min(_probeConcurrency, _maxProbe - probes),
        );
        if (batch.isNotEmpty) {
          probes += batch.length;
          final hit = await _probe(batch);
          if (hit != null) {
            return hit;
          }
          continue;
        }
      } else {
        // 探测名额用完：池子里还有候选就留给下次上滑，别急着喊「没有更多」
        return null;
      }

      if (pages >= maxPages) {
        return null;
      }
      pages++;
      if (relatedFirst) {
        relatedFirst = false;
        await _fillRelated(currentBvid);
        continue;
      }
      final int added = await _fillHomeRcmd();
      // 首页推荐拿不到东西（未登录被拦、风控等）就退回相关推荐
      if (added == 0 && !relatedUsed) {
        relatedUsed = true;
        await _fillRelated(currentBvid);
      }
    }
  }

  /// 清掉不能用的候选：当前视频、历史里播过的、已确认横屏的、拉黑过的
  void _purge(String currentBvid) {
    for (int i = _queue.length - 1; i >= 0; i--) {
      final item = _queue[i];
      final bool horizontal = item.isKnown && !item.isVertical;
      if (item.bvid == currentBvid ||
          _rejected.contains(item.bvid) ||
          horizontal ||
          _history.any((e) => e.bvid == item.bvid)) {
        if (horizontal) {
          _rejected.add(item.bvid);
        }
        _queue.removeAt(i);
      }
    }
  }

  PortraitFeedItem? _takeVertical(String currentBvid) {
    _purge(currentBvid);
    final List<int> verticals = [
      for (int i = 0; i < _queue.length; i++)
        if (_queue[i].isVertical) i,
    ];
    if (verticals.isEmpty) {
      return null;
    }
    final int index = Pref.portraitRandom
        ? verticals[_random.nextInt(verticals.length)]
        : verticals.first;
    return _queue.removeAt(index);
  }

  /// 取一批「尺寸未知、要探测」的候选，短的优先（竖屏基本都是短视频）
  List<PortraitFeedItem> _takeUnknown(String currentBvid, int max) {
    _purge(currentBvid);
    if (_queue.isEmpty || max <= 0) {
      return const <PortraitFeedItem>[];
    }
    final List<PortraitFeedItem> candidates = [..._queue];
    if (Pref.portraitRandom) {
      candidates.shuffle(_random);
    } else {
      candidates.sort(
        (a, b) => _probePriority(a).compareTo(_probePriority(b)),
      );
    }
    final List<PortraitFeedItem> taken =
        candidates.take(min(max, candidates.length)).toList();
    _queue.removeWhere(taken.contains);
    return taken;
  }

  static int _probePriority(PortraitFeedItem item) =>
      _durationPriority(item) + item.probeFails * 10;

  /// 短的平均命中率高，先探；时长未知的排在中间，长视频最后再看
  static int _durationPriority(PortraitFeedItem item) {
    final int? duration = item.duration;
    if (duration == null || duration <= 0) {
      return 3;
    }
    if (duration <= 60) {
      return 0;
    }
    if (duration <= 180) {
      return 1;
    }
    if (duration <= 300) {
      return 2;
    }
    return 4;
  }

  /// 并发探测一批候选，返回其中第一条竖屏视频
  Future<PortraitFeedItem?> _probe(List<PortraitFeedItem> batch) async {
    final results = await Future.wait(batch.map(_ensureVertical));
    PortraitFeedItem? hit;
    for (int i = 0; i < batch.length; i++) {
      final item = batch[i];
      if (results[i]) {
        if (hit == null) {
          hit = item;
        } else {
          // 顺带发现的竖屏视频留在池子里，下次上滑直接可用
          _queue.add(item);
        }
      } else if (item.isKnown) {
        // 探测成功但确实是横屏，拉黑
        _rejected.add(item.bvid);
      } else {
        // 网络/风控失败：不是横屏，留着下次再试
        item.probeFails++;
        _queue.add(item);
      }
    }
    return hit;
  }

  Future<bool> _ensureVertical(PortraitFeedItem item) async {
    if (item.isKnown) {
      return item.isVertical;
    }
    try {
      final res = await SearchHttp.ab2cWithDimension(
        aid: item.aid,
        bvid: item.bvid,
        toastError: false,
      );
      final dimension = res?.dimension;
      if (res == null || dimension == null) {
        return false;
      }
      item.cid ??= res.cid;
      item.dimension = dimension;
      item.vertical = dimension.isVertical;
      return dimension.isVertical;
    } catch (_) {
      return false;
    }
  }

  bool _add(PortraitFeedItem item) {
    final String bvid = item.bvid;
    if (bvid.isEmpty || bvid == _cursor) {
      return false;
    }
    if (_rejected.contains(bvid)) {
      return false;
    }
    if (_queue.any((e) => e.bvid == bvid) ||
        _history.any((e) => e.bvid == bvid)) {
      return false;
    }
    if (item.isKnown && !item.isVertical) {
      _rejected.add(bvid);
      return false;
    }
    _queue.add(item);
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    return true;
  }

  /// 首页推荐：官方就是拿这个池子刷竖屏，分页往后取，取不完
  Future<int> _fillHomeRcmd() {
    final pending = _homeFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<int> future;
    future = _doFillHomeRcmd().whenComplete(() {
      if (identical(_homeFuture, future)) {
        _homeFuture = null;
      }
    });
    _homeFuture = future;
    return future;
  }

  Future<int> _doFillHomeRcmd() async {
    // 先吃 App 端推荐池：条目自带竖屏标记，绝大多数候选零成本就能判尺寸
    int added = await _doFillAppRcmd();
    if (added == 0) {
      added = await _doFillWebRcmd();
    }
    return added;
  }

  /// App 端推荐：rcmd_reason 为「竖屏」、uri 上带 player_width/player_height
  Future<int> _doFillAppRcmd() async {
    int added = 0;
    try {
      final res = await VideoHttp.rcmdVideoListApp(freshIdx: _appIdx);
      if (res case Success(:final response)) {
        _appIdx++;
        for (final e in response) {
          if (e.goto != 'av') {
            continue;
          }
          if (_add(
            PortraitFeedItem(
              bvid: e.bvid ?? '',
              cid: e.cid,
              aid: e.aid,
              cover: e.cover,
              title: e.title,
              duration: e.duration,
              dimension: _dimensionFromUri(e.uri),
              vertical: e.portrait ? true : null,
            ),
          )) {
            added++;
          }
        }
      }
    } catch (_) {}
    return added;
  }

  Future<int> _doFillWebRcmd() async {
    int added = 0;
    try {
      final res = await VideoHttp.rcmdVideoList(ps: 20, freshIdx: _webIdx);
      if (res case Success(:final response)) {
        _webIdx++;
        for (final e in response) {
          if (_add(
            PortraitFeedItem(
              bvid: e.bvid ?? '',
              cid: e.cid,
              aid: e.aid,
              cover: e.cover,
              title: e.title,
              duration: e.duration,
              dimension: e.dimension,
            ),
          )) {
            added++;
          }
        }
      }
    } catch (_) {}
    return added;
  }

  /// 官方 App 的推荐 uri 上就带着画面尺寸，能直接判竖屏，不必再探测
  static Dimension? _dimensionFromUri(String? uri) {
    if (uri == null || uri.isEmpty) {
      return null;
    }
    try {
      final params = Uri.parse(uri).queryParameters;
      final int? width = int.tryParse(params['player_width'] ?? '');
      final int? height = int.tryParse(params['player_height'] ?? '');
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      return params['player_rotate'] == '1'
          ? Dimension(width: height, height: width)
          : Dimension(width: width, height: height);
    } catch (_) {
      return null;
    }
  }

  Future<int> _fillRelated(String bvid) {
    final pending = _relatedFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<int> future;
    future = _doFillRelated(bvid).whenComplete(() {
      if (identical(_relatedFuture, future)) {
        _relatedFuture = null;
      }
    });
    _relatedFuture = future;
    return future;
  }

  Future<int> _doFillRelated(String bvid) async {
    int added = 0;
    try {
      final res = await VideoHttp.relatedVideoList(bvid: bvid);
      if (res case Success(:final response)) {
        for (final HotVideoItemModel e
            in response ?? const <HotVideoItemModel>[]) {
          if (e.isLive == true || e.isPugv == true) {
            continue;
          }
          if (e.redirectUrl?.isNotEmpty == true) {
            continue;
          }
          if (_add(
            PortraitFeedItem(
              bvid: e.bvid ?? '',
              cid: e.cid,
              aid: e.aid,
              cover: e.cover,
              title: e.title,
              duration: e.duration,
              dimension: e.dimension,
            ),
          )) {
            added++;
          }
        }
      }
    } catch (_) {}
    return added;
  }
}
