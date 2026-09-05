import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../shared/widgets.dart';
import '../onboarding/onboarding_flow.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.state, super.key});
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.state.refreshDeviceStatuses();
    });
  }

  Future<void> _pairNewDevice() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => OnboardingFlow(
          state: widget.state,
          showIntro: false,
          onFinished: () async {
            if (routeContext.mounted) Navigator.of(routeContext).pop();
          },
        ),
      ),
    );
    if (mounted) await widget.state.refreshDeviceStatuses();
  }

  Future<void> _confirmClearDownloads() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Clear downloaded clips?'),
            content: Text(
              'This removes ${widget.state.downloadedClips.length} local '
              '${widget.state.downloadedClips.length == 1 ? 'clip' : 'clips'} from this device. Clips remain on your PC.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear Downloads'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) await widget.state.clearDownloadedClips();
  }

  Future<void> _confirmForget(Connection connection) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Forget ${connection.computerName}?'),
            content: const Text(
                'You will need a new pairing code to connect again.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Forget Device'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) await widget.state.forget(connection);
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.state.active == null
        ? null
        : widget.state.serverInfos[widget.state.active!.serverId];
    return RefreshIndicator(
      onRefresh: widget.state.refreshDeviceStatuses,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              'Settings',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const _SectionLabel('Paired PCs'),
          for (final connection in widget.state.connections)
            _DeviceTile(
              connection: connection,
              status: widget.state.deviceStatuses[connection.serverId] ??
                  const DeviceStatus.checking(),
              selected: connection.serverId == widget.state.activeServerId,
              onTap: () => widget.state.select(connection),
              onForget: () => _confirmForget(connection),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: OutlinedButton.icon(
              onPressed: _pairNewDevice,
              icon: const Icon(Icons.add),
              label: const Text('Pair a New Device'),
            ),
          ),
          if (server != null) ...[
            const _SectionLabel('Connected Desktop'),
            ListTile(
              leading: const Icon(Icons.computer_outlined),
              title: Text(server.computerName),
              subtitle: Text(
                'ShadowPlay ${server.serverVersion ?? 'version unavailable'} · API v${server.apiVersion}',
              ),
            ),
          ],
          const _SectionLabel('Downloads'),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Storage used'),
            subtitle: Text('${widget.state.downloadedClips.length} clips'),
            trailing: Text(formatBytes(widget.state.storageUsedBytes)),
          ),
          ListTile(
            enabled: widget.state.downloadedClips.isNotEmpty,
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear downloaded clips'),
            subtitle: const Text('Keeps the original files on your PC'),
            onTap: _confirmClearDownloads,
          ),
          const _SectionLabel('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.video_library_outlined),
            title: const Text('New clips'),
            subtitle: const Text('Notify when new PC clips are available'),
            value: widget.state.newClipNotifications,
            onChanged: widget.state.setNewClipNotifications,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.download_done),
            title: const Text('Downloads complete'),
            subtitle:
                const Text('Notify when selected clips finish downloading'),
            value: widget.state.downloadNotifications,
            onChanged: widget.state.setDownloadNotifications,
          ),
          const _SectionLabel('Appearance'),
          ListTile(
            leading: const Icon(Icons.contrast),
            title: const Text('Theme'),
            subtitle: Text(switch (widget.state.themeMode) {
              ThemeMode.system => 'System',
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark'
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (context) => SafeArea(
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                          for (final mode in ThemeMode.values)
                            ListTile(
                              title: Text(switch (mode) {
                                ThemeMode.system => 'System',
                                ThemeMode.light => 'Light',
                                ThemeMode.dark => 'Dark'
                              }),
                              leading: Icon(switch (mode) {
                                ThemeMode.system => Icons.brightness_auto,
                                ThemeMode.light => Icons.light_mode_outlined,
                                ThemeMode.dark => Icons.dark_mode_outlined
                              }),
                              trailing: widget.state.themeMode == mode
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () {
                                widget.state.setThemeMode(mode);
                                Navigator.pop(context);
                              },
                            ),
                        ])))),
          ),
          const _SectionLabel('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('ShadowPlay'),
            subtitle: Text('Version 0.1.0 (1)'),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('About this app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'ShadowPlay',
              applicationVersion: '0.1.0 (1)',
              children: const [
                Text(
                    'A private LAN client for downloading original game clips from your paired PC.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      );
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.connection,
    required this.status,
    required this.selected,
    required this.onTap,
    required this.onForget,
  });

  final Connection connection;
  final DeviceStatus status;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final online = status.availability == DeviceAvailability.online;
    final checking = status.availability == DeviceAvailability.checking;
    return ListTile(
      leading: Stack(
        clipBehavior: ui.Clip.none,
        children: [
          const Icon(Icons.desktop_windows_outlined, size: 30),
          Positioned(
            right: -2,
            bottom: -1,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: checking
                    ? Theme.of(context).colorScheme.outline
                    : online
                        ? const Color(0xFF2E9D59)
                        : Theme.of(context).colorScheme.error,
                border: Border.all(
                    color: Theme.of(context).colorScheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
              child: Text(connection.computerName,
                  overflow: TextOverflow.ellipsis)),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_circle,
                size: 16, color: Theme.of(context).colorScheme.primary),
          ],
        ],
      ),
      subtitle: Text(
        checking
            ? 'Checking…'
            : online
                ? 'Online · ${_lastSeen(connection.lastSeenUtc)}'
                : 'Offline · ${_lastSeen(connection.lastSeenUtc)}',
      ),
      onTap: onTap,
      trailing: IconButton(
        tooltip: 'Forget device',
        onPressed: onForget,
        icon: const Icon(Icons.link_off),
      ),
    );
  }

  String _lastSeen(DateTime? value) {
    if (value == null) return 'last seen unknown';
    final difference = DateTime.now().toUtc().difference(value.toUtc());
    if (difference.inMinutes < 1) return 'seen just now';
    if (difference.inHours < 1) return 'seen ${difference.inMinutes} min ago';
    if (difference.inDays < 1) return 'seen ${difference.inHours} hr ago';
    return 'seen ${difference.inDays} d ago';
  }
}
