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
    this.dimension,
  });

  final String bvid;
  int? cid;
  final int? aid;
  final String? cover;
  final String? title;
  Dimension? dimension;

  bool get isVertical => dimension?.isVertical == true;
}

/// 竖屏即刷的取流：
///
/// 行为对齐官方客户端：从推荐池里一条条往下刷，池子空了就自动取下一页，
/// 只要网络还在就不会「刷不出视频」。推荐页里绝大多数是横屏，这里只留下
/// 已知竖屏的条目，尺寸未知的才发一次 pagelist 探测，探测名额有限，避免
/// 上滑时被几十个请求拖住。
class PortraitFeedService {
  PortraitFeedService._();

  static final PortraitFeedService instance = PortraitFeedService._();

  /// 上滑回退栈上限
  static const int _maxHistory = 50;

  /// 一次切换最多探测几个「尺寸未知」的候选
  static const int _maxProbe = 6;

  /// 一次切换最多续取几页推荐（关掉「自动续取推荐」时只取一页）
  static const int _maxPages = 4;

  /// 候选池上限，长时间挂着也不会无限堆
  static const int _maxQueue = 150;

  final List<PortraitFeedItem> _queue = [];
  final List<PortraitFeedItem> _history = [];

  /// 已经确认不是竖屏的 bvid，避免反复回锅探测
  final Set<String> _rejected = <String>{};

  /// 开启「随机视频」后从候选池里随机取，而不是按推荐顺序依次取
  final Random _random = Random();

  String? _cursor;
  int _homeIdx = 0;

  Future<void>? _homeFuture;
  Future<void>? _relatedFuture;

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

  /// 关闭「竖屏即刷」或换页面时彻底清空，连首页推荐的分页游标一起重置，
  /// 下次打开从头开始取推荐
  void reset() {
    clear();
    _homeIdx = 0;
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
    int probes = 0;
    int pages = 0;
    // 关掉「使用首页推荐」时先用当前视频的相关推荐，用完后自动接首页推荐
    bool relatedFirst = !Pref.portraitRC;
    bool triedRelated = !Pref.portraitRC;

    while (true) {
      final item = _take(currentBvid);
      if (item == null) {
        if (pages >= maxPages) {
          return null;
        }
        if (relatedFirst) {
          relatedFirst = false;
          triedRelated = true;
          await _fillRelated(currentBvid);
        } else {
          final int before = _queue.length;
          await _fillHomeRcmd();
          // 首页推荐拿不到东西（未登录被拦、风控等）就退回相关推荐
          if (_queue.length == before && !triedRelated) {
            triedRelated = true;
            await _fillRelated(currentBvid);
          }
        }
        pages++;
        continue;
      }
      if (item.isVertical) {
        return item;
      }
      if (probes >= _maxProbe) {
        return null;
      }
      probes++;
      if (await _ensureVertical(item)) {
        return item;
      }
      // 探测成功但其实不是竖屏才拉黑；网络失败留到下次再试
      if (item.dimension != null) {
        _rejected.add(item.bvid);
      }
    }
  }

  PortraitFeedItem? _take(String currentBvid) {
    for (int i = _queue.length - 1; i >= 0; i--) {
      final item = _queue[i];
      if (item.bvid == currentBvid ||
          _rejected.contains(item.bvid) ||
          _history.any((e) => e.bvid == item.bvid)) {
        _queue.removeAt(i);
        continue;
      }
      // 推荐页里已经写明是横屏的直接丢掉，不再浪费探测名额
      if (item.dimension != null && !item.isVertical) {
        _rejected.add(item.bvid);
        _queue.removeAt(i);
      }
    }
    if (_queue.isEmpty) {
      return null;
    }
    // 优先取已知竖屏的候选
    final List<int> verticals = [
      for (int i = 0; i < _queue.length; i++)
        if (_queue[i].isVertical) i,
    ];
    if (verticals.isNotEmpty) {
      final int index = Pref.portraitRandom
          ? verticals[_random.nextInt(verticals.length)]
          : verticals.first;
      return _queue.removeAt(index);
    }
    // 只剩尺寸未知的候选，取一个去探测
    final int index = Pref.portraitRandom
        ? _random.nextInt(_queue.length)
        : 0;
    return _queue.removeAt(index);
  }

  void _add(PortraitFeedItem item) {
    final String bvid = item.bvid;
    if (bvid.isEmpty || bvid == _cursor) {
      return;
    }
    if (_rejected.contains(bvid)) {
      return;
    }
    if (_queue.any((e) => e.bvid == bvid) ||
        _history.any((e) => e.bvid == bvid)) {
      return;
    }
    if (item.dimension != null && !item.isVertical) {
      _rejected.add(bvid);
      return;
    }
    _queue.add(item);
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
  }

  Future<bool> _ensureVertical(PortraitFeedItem item) async {
    if (item.dimension != null) {
      return item.isVertical;
    }
    try {
      final res = await SearchHttp.ab2cWithDimension(
        aid: item.aid,
        bvid: item.bvid,
        toastError: false,
      );
      if (res == null) {
        return false;
      }
      item.cid ??= res.cid;
      item.dimension = res.dimension;
      return item.isVertical;
    } catch (_) {
      return false;
    }
  }

  /// 首页推荐：官方就是拿这个池子刷竖屏，分页往后取，取不完
  Future<void> _fillHomeRcmd() {
    final pending = _homeFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<void> future;
    future = _doFillHomeRcmd().whenComplete(() {
      if (identical(_homeFuture, future)) {
        _homeFuture = null;
      }
    });
    _homeFuture = future;
    return future;
  }

  Future<void> _doFillHomeRcmd() async {
    try {
      final res = await VideoHttp.rcmdVideoList(ps: 20, freshIdx: _homeIdx);
      if (res case Success(:final response)) {
        _homeIdx++;
        for (final e in response) {
          _add(
            PortraitFeedItem(
              bvid: e.bvid ?? '',
              cid: e.cid,
              aid: e.aid,
              cover: e.cover,
              title: e.title,
              dimension: e.dimension,
            ),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _fillRelated(String bvid) {
    final pending = _relatedFuture;
    if (pending != null) {
      return pending;
    }
    late final Future<void> future;
    future = _doFillRelated(bvid).whenComplete(() {
      if (identical(_relatedFuture, future)) {
        _relatedFuture = null;
      }
    });
    _relatedFuture = future;
    return future;
  }

  Future<void> _doFillRelated(String bvid) async {
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
          _add(
            PortraitFeedItem(
              bvid: e.bvid ?? '',
              cid: e.cid,
              aid: e.aid,
              cover: e.cover,
              title: e.title,
              dimension: e.dimension,
            ),
          );
        }
      }
    } catch (_) {}
  }
}
