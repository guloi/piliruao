import 'dart:math';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart' show CancelToken;

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

/// 取流统计：设置页会把最近一次的结果显示出来，方便看清到底是「推荐池里
/// 本来就没有竖屏」还是「尺寸探测没成功」才刷不出视频
/// 统计是累计的，不按单次取流清零：单次取流大多是「池子里直接有货」的
/// 0 请求命中，按次看全零反而看不出问题
class PortraitFeedStats {
  /// App 端推荐池累计返回多少条、其中判为竖屏多少条
  int appItems = 0;
  int appVerticals = 0;

  /// App 条目里带「竖屏」推荐标记的条数、uri 上直接带画面尺寸的条数
  /// （两者就是「零请求判竖屏」的全部依据，看这两个数就知道能不能白捧）
  int appMarked = 0;
  int appSized = 0;

  /// Web 端推荐池
  int webItems = 0;
  int webVerticals = 0;

  /// 当前视频的相关推荐
  int relatedItems = 0;
  int relatedVerticals = 0;

  /// pagelist 探测次数与失败次数（失败大多是网络/风控，不是真的横屏）
  int probes = 0;
  int probeFailed = 0;

  /// 取流次数与空手而归的次数
  int searches = 0;
  int misses = 0;

  /// 有没有用过「刷新推荐」这招兜底
  bool refreshed = false;
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

  /// 一次上滑最多同时探测几条候选（并发高了下游 HTTP/2 连接会被压爆，
  /// 其他页面就会报「网络异常」）
  static const int _probeConcurrency = 3;

  /// 一次上滑最多探测几条候选，超过就把剩下的留给下次上滑。
  /// 不能往高了调：这里每一条都是一次 pagelist 请求，打太密会把整个 App 的
  /// 请求队列拖住（其他页面就会「网络异常」、跳转晚好几秒）
  static const int _maxProbe = 8;

  /// 一次上滑的探测时间预算，超时先返回，下次上滑接着找
  static const Duration _probeBudget = Duration(seconds: 4);

  /// 一次切换最多续取几页推荐（关掉「自动续取推荐」时只取一页）
  static const int _maxPages = 2;

  final List<PortraitFeedItem> _queue = [];
  final List<PortraitFeedItem> _history = [];

  /// 已经确认不是竖屏的 bvid，避免反复回锅探测
  final Set<String> _rejected = <String>{};

  /// 开启「随机视频」后从候选池里随机取，而不是按推荐顺序依次取
  final Random _random = Random();

  /// 最近一次取流的统计（设置页会显示）
  final PortraitFeedStats stats = PortraitFeedStats();

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

  /// 预取代次：切页/清空时递增，旧任务跑完后按代次丢弃结果
  int _prefetchSeq = 0;

  /// 后台取流共用的取消令牌：换页/点链接跳转时取消，别和详情请求抢连接
  CancelToken _cancelToken = CancelToken();

  void _cancelInFlight() {
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('portrait feed aborted');
    }
    _cancelToken = CancelToken();
    // 旧的分页/取流 future 已经作废，别让下一次取流继续等它们
    _homeFuture = null;
    _relatedFuture = null;
    _searchFuture = null;
    _searchFor = null;
  }

  /// 用户主动跳转（点链接、剪切板）前调用：立刻停掉后台探测/预取
  void abortBackground() {
    _cancelInFlight();
    _dropPrefetch();
  }

  String? get cursor => _cursor;

  int get historyLength => _history.length;

  bool get canGoPrevious => _history.isNotEmpty;

  /// 候选池里还有没试完的东西（此时刷不出只是这一轮没找到，不算真的没货）
  bool get hasPending => _queue.isNotEmpty;

  void visit(String bvid) {
    if (_cursor == bvid) {
      return;
    }
    final int index = _history.indexWhere((e) => e.bvid == bvid);
    if (index == -1) {
      // 打开了另一个视频（链接/剪切板跳转）：旧视频的后台探测到此为止
      _cancelInFlight();
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
    _cancelInFlight();
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
    // 只在竖屏全屏真正可用时才会被调用（见 VideoDetailPageV._preloadPortraitFeed）：
    // 打开视频详情页、点链接跳转时一条后台请求都不发，避免抢走详情/跳转的请求配额
    if (currentBvid.isEmpty) return;
    if (_prefetchedFor == currentBvid && _prefetched != null) return;
    // 预取也必须单飞：同一时间只允许一个后台任务。之前只按 bvid 去重，
    // 换视频时旧预取还在跑、新页面又起一份，请求就会叠起来
    if (_prefetchFuture != null) return;
    final int seq = ++_prefetchSeq;
    _prefetchingFor = currentBvid;
    late final Future<void> future;
    future = _findNext(currentBvid, cheap: true)
        .then((item) {
          // 页面已经切走（代次变了）就丢弃结果，别再往池子里塞旧视频
          if (seq != _prefetchSeq) return;
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

  Future<PortraitFeedItem?>? _searchFuture;
  String? _searchFor;

  /// 取流单飞：同一个视频只跑一场。不同视频不能直接复用旧任务，
  /// 否则会拿旧视频的结果去切换新页面（表现为点了链接却跳到别的视频）。
  Future<PortraitFeedItem?> _search(String currentBvid) {
    final pending = _searchFuture;
    if (pending != null) {
      if (_searchFor == currentBvid) {
        return pending;
      }
      // 旧任务还在跑：等它结束再为当前视频取流，避免两场取流并发打请求
      return pending
          .catchError((Object _) => null)
          .then((_) => _search(currentBvid));
    }
    late final Future<PortraitFeedItem?> future;
    _searchFor = currentBvid;
    future = _findNext(currentBvid).whenComplete(() {
      if (identical(_searchFuture, future)) {
        _searchFuture = null;
        _searchFor = null;
      }
    });
    _searchFuture = future;
    return future;
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
    _prefetchSeq++;
    _prefetched = null;
    _prefetchedFor = null;
    _prefetchingFor = null;
    // 注意不要置空 _prefetchFuture：它没有取消，置空后下一个页面会再起一份，
    // 旧请求 + 新请求就叠成一场小风暴。让它自然跑完，结果按代次丢弃
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
    return _search(currentBvid);
  }

  /// [cheap] 为 true 是后台预取专用的廉价模式：只翻一页推荐、只捡白送的
  /// 竖屏，绝不发 pagelist 探测。用户点卡片/跳转的时候后台不会有几十个
  /// 请求抢配额，不会再出现「网络异常 + 5 秒后才跳转」。
  Future<PortraitFeedItem?> _findNext(
    String currentBvid, {
    bool cheap = false,
  }) async {
    // 关掉「自动续取推荐」就只允许取一页，否则一直往后翻，刷不完
    final int maxPages = cheap ? 1 : (Pref.portraitNewv ? _maxPages : 1);
    stats.searches++;
    int probes = 0;

    // 池子里已经有确认竖屏的，直接给，一个请求都不用发
    final ready = _takeVertical(currentBvid);
    if (ready != null) {
      return ready;
    }

    // 关掉「使用首页推荐」时先吃当前视频的相关推荐
    bool relatedTried = false;
    if (!Pref.portraitRC) {
      relatedTried = true;
      await _fillRelated(currentBvid);
      final related = _takeVertical(currentBvid);
      if (related != null) {
        return related;
      }
    }

    final int itemsBefore = stats.appItems + stats.webItems;
    bool refreshed = false;

    // 先把首页推荐池往下翻：能白捡到竖屏，就别花探测名额。翻到某一页
    // 有竖屏立刻返回，不会为了「多备点货」把网络全占住
    for (int page = 0; page < maxPages; page++) {
      await _fillHomeRcmd();
      final item = _takeVertical(currentBvid);
      if (item != null) {
        return item;
      }
    }

    // 翻到底还是一条竖屏都没有：把推荐流刷新一次（等价官方下拉刷新）
    if (!cheap && !refreshed) {
      refreshed = true;
      stats.refreshed = true;
      _appIdx = 0;
      _webIdx = 0;
      await _fillHomeRcmd();
      final item = _takeVertical(currentBvid);
      if (item != null) {
        return item;
      }
    }

    // 再退一步：池子里尺寸未知的候选并发探测（短视频优先，不会试几条就放弃）
    // 探测预算从翻完页才开始算，否则翻页把时间吃光就一条都探不了了
    if (!cheap) {
      final Stopwatch probeWatch = Stopwatch()..start();
      while (probes < _maxProbe && probeWatch.elapsed < _probeBudget) {
        final batch = _takeUnknown(
          currentBvid,
          min(_probeConcurrency, _maxProbe - probes),
        );
        if (batch.isEmpty) {
          break;
        }
        probes += batch.length;
        final hit = await _probe(batch);
        if (hit != null) {
          return hit;
        }
      }
    }

    // 首页推荐一条都没拿到（未登录被拦、风控等）才退回相关推荐，
    // 正常情况不用它，免得给你刷一屏「全是当前视频同款」的内容
    if (!cheap &&
        !relatedTried &&
        stats.appItems + stats.webItems == itemsBefore) {
      await _fillRelated(currentBvid);
      final related = _takeVertical(currentBvid);
      if (related != null) {
        return related;
      }
    }

    stats.misses++;
    return null;
  }

  /// 给设置页看的累计统计（单次取流大多是 0 请求命中，按次看反而全是 0）
  String get statsSummary => '累计：App ${stats.appItems}条/竖屏${stats.appVerticals}'
      '（标记${stats.appMarked}/带尺寸${stats.appSized}）'
      '，Web ${stats.webItems}条/竖屏${stats.webVerticals}'
      '，相关 ${stats.relatedItems}条/竖屏${stats.relatedVerticals}'
      '，探测 ${stats.probes} 条（失败 ${stats.probeFailed}）'
      '，取流 ${stats.searches} 次/落空 ${stats.misses} 次'
      '，池内 ${_queue.length} 条';

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
    // 探测顺序按「像竖屏」程度排（短的先探），命中率比乱序高很多；
    // 随机只体现在最终选哪一条竖屏视频上
    candidates.sort((a, b) => _probePriority(a).compareTo(_probePriority(b)));
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
    stats.probes += batch.length;
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
        stats.probeFailed++;
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
        silent: true,
        cancelToken: _cancelToken,
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
    final int itemsBefore = stats.appItems;
    int added = await _doFillAppRcmd();
    // App 池一条都没拿到才去问 Web 池（Web 池几乎全是横屏，只能靠探测）
    if (stats.appItems == itemsBefore) {
      added = await _doFillWebRcmd() + added;
    }
    return added;
  }

  /// App 端推荐：rcmd_reason 为「竖屏」、uri 上带 player_width/player_height
  Future<int> _doFillAppRcmd() async {
    int added = 0;
    try {
      final res = await VideoHttp.rcmdVideoListApp(
        freshIdx: _appIdx,
        silent: true,
        cancelToken: _cancelToken,
      );
      if (res case Success(:final response)) {
        _appIdx++;
        int verticals = 0;
        int marked = 0;
        int sized = 0;
        for (final e in response) {
          if (e.goto != 'av') {
            continue;
          }
          if (e.portrait) {
            marked++;
          }
          final dimension = _dimensionFromUri(e.uri);
          if (dimension != null) {
            sized++;
          }
          final item = PortraitFeedItem(
            bvid: e.bvid ?? '',
            cid: e.cid,
            aid: e.aid,
            cover: e.cover,
            title: e.title,
            duration: e.duration,
            dimension: dimension,
            vertical: e.portrait ? true : null,
          );
          if (item.isVertical) {
            verticals++;
          }
          if (_add(item)) {
            added++;
          }
        }
        stats
          ..appItems += response.length
          ..appVerticals += verticals
          ..appMarked += marked
          ..appSized += sized;
      }
    } catch (_) {}
    return added;
  }

  Future<int> _doFillWebRcmd() async {
    int added = 0;
    try {
      final res = await VideoHttp.rcmdVideoList(
        ps: 20,
        freshIdx: _webIdx,
        silent: true,
        cancelToken: _cancelToken,
      );
      if (res case Success(:final response)) {
        _webIdx++;
        int verticals = 0;
        for (final e in response) {
          final item = PortraitFeedItem(
            bvid: e.bvid ?? '',
            cid: e.cid,
            aid: e.aid,
            cover: e.cover,
            title: e.title,
            duration: e.duration,
            dimension: e.dimension,
          );
          if (item.isVertical) {
            verticals++;
          }
          if (_add(item)) {
            added++;
          }
        }
        stats
          ..webItems += response.length
          ..webVerticals += verticals;
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
      final res = await VideoHttp.relatedVideoList(
        bvid: bvid,
        silent: true,
        cancelToken: _cancelToken,
      );
      if (res case Success(:final response)) {
        int verticals = 0;
        for (final HotVideoItemModel e
            in response ?? const <HotVideoItemModel>[]) {
          if (e.isLive == true || e.isPugv == true) {
            continue;
          }
          if (e.redirectUrl?.isNotEmpty == true) {
            continue;
          }
          final item = PortraitFeedItem(
            bvid: e.bvid ?? '',
            cid: e.cid,
            aid: e.aid,
            cover: e.cover,
            title: e.title,
            duration: e.duration,
            dimension: e.dimension,
          );
          if (item.isVertical) {
            verticals++;
          }
          if (_add(item)) {
            added++;
          }
        }
        stats
          ..relatedItems += response?.length ?? 0
          ..relatedVerticals += verticals;
      }
    } catch (_) {}
    return added;
  }
}
