part of 'launcher.dart';

class _HomeHeader extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback onMenu;
  final VoidCallback onNotifications;
  final VoidCallback? onMessages;
  final VoidCallback? onChat;
  final WappManifest? messagesWapp;
  final WappManifest? chatWapp;

  const _HomeHeader({
    required this.onMenu,
    required this.onNotifications,
    this.onMessages,
    this.onChat,
    this.messagesWapp,
    this.chatWapp,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.menu),
        tooltip: 'Menu',
        onPressed: onMenu,
      ),
      titleSpacing: 0,
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProfileSwitcher(),
          SizedBox(width: 10),
          _ConnectionIndicator(),
        ],
      ),
      actions: [
        ValueListenableBuilder<int>(
          valueListenable: NotificationStore.instance.unreadCount,
          builder: (context, count, _) => _BadgedActionIcon(
            icon: Icons.notifications_none,
            tooltip: 'Notifications',
            count: count,
            onPressed: onNotifications,
          ),
        ),
        if (messagesWapp != null && onMessages != null)
          _IntentBadgeIcon(
            icon: Icons.mail_outline,
            tooltip: 'Messages',
            wappId: BackgroundWappManager.folderName(messagesWapp!.dirPath),
            intent: 'messages',
            includeLxmf: true,
            onPressed: onMessages!,
          ),
        if (chatWapp != null && onChat != null)
          _IntentBadgeIcon(
            icon: Icons.forum_outlined,
            tooltip: 'Chat',
            wappId: BackgroundWappManager.folderName(chatWapp!.dirPath),
            intent: 'chat',
            onPressed: onChat!,
          ),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _IntentBadgeIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final String wappId;
  final String intent;
  final bool includeLxmf;
  final VoidCallback onPressed;

  const _IntentBadgeIcon({
    required this.icon,
    required this.tooltip,
    required this.wappId,
    required this.intent,
    required this.onPressed,
    this.includeLxmf = false,
  });

  @override
  State<_IntentBadgeIcon> createState() => _IntentBadgeIconState();
}

class _IntentBadgeIconState extends State<_IntentBadgeIcon> {
  @override
  void initState() {
    super.initState();
    if (widget.includeLxmf) {
      RnsService.instance.addLxmfListener(_refresh);
    }
  }

  @override
  void didUpdateWidget(covariant _IntentBadgeIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.includeLxmf != widget.includeLxmf) {
      if (oldWidget.includeLxmf) {
        RnsService.instance.removeLxmfListener(_refresh);
      }
      if (widget.includeLxmf) {
        RnsService.instance.addLxmfListener(_refresh);
      }
    }
  }

  @override
  void dispose() {
    if (widget.includeLxmf) {
      RnsService.instance.removeLxmfListener(_refresh);
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: WappUnreadService.instance.counts,
      builder: (context, _, child) {
        final wappCount = WappUnreadService.instance.countFor(
          widget.wappId,
          intent: widget.intent,
        );
        final lxmf = widget.includeLxmf
            ? RnsService.instance.lxmfUnreadCount
            : 0;
        return _BadgedActionIcon(
          icon: widget.icon,
          tooltip: widget.tooltip,
          count: wappCount + lxmf,
          onPressed: widget.onPressed,
        );
      },
    );
  }
}

class _BadgedActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final int count;
  final VoidCallback onPressed;

  const _BadgedActionIcon({
    required this.icon,
    required this.tooltip,
    required this.count,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPressed),
        if (count > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 17),
              decoration: BoxDecoration(
                color: const Color(0xFFda3633),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Text(
                count > 99 ? '99+' : '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
