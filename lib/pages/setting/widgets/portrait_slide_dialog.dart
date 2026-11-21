import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/services/portrait_feed_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

Future<void> portraitSlideDialog(BuildContext context) async {
  var subtreeKey = UniqueKey();

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        title: const Text('竖屏即刷'),
        contentPadding: const EdgeInsets.only(top: 8, bottom: 4),
        content: SingleChildScrollView(
          child: KeyedSubtree(
            key: subtreeKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(Icons.swipe_up_outlined),
                  title: Text('竖屏视频全屏播放时'),
                  subtitle: Text('上滑播放推荐的竖屏视频，下滑回到上一个视频，播完自动上滑'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
                  child: Text(
                    PortraitFeedService.instance.stats.summary,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SetSwitchItem(
                  title: '使用首页推荐',
                  subtitle: Pref.portraitRC
                      ? '当前：首页推荐（和官方一致，一直刷不完）'
                      : '当前：当前视频的相关推荐，用完后自动接首页推荐',
                  setKey: SettingBoxKey.portraitRC,
                  defaultVal: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  onChanged: (_) => setState(() {}),
                ),
                SetSwitchItem(
                  title: '随机视频',
                  subtitle: Pref.portraitRandom
                      ? '当前：从候选池里随机挑一个竖屏视频'
                      : '当前：按推荐顺序依次刷',
                  setKey: SettingBoxKey.portraitRandom,
                  defaultVal: false,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  onChanged: (_) => setState(() {}),
                ),
                SetSwitchItem(
                  title: '自动续取推荐',
                  subtitle: Pref.portraitNewv
                      ? '当前：没刷出竖屏视频时自动取下一页推荐'
                      : '当前：只在已经取到的推荐里找，找完就停',
                  setKey: SettingBoxKey.portraitNewv,
                  defaultVal: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () async {
              await GStorage.setting.put(SettingBoxKey.portraitRC, true);
              await GStorage.setting.put(SettingBoxKey.portraitNewv, true);
              await GStorage.setting.put(SettingBoxKey.portraitRandom, false);

              setState(() => subtreeKey = UniqueKey());
            },
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
