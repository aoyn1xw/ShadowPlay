import 'package:flutter/material.dart';

import '../core/models.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(title,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      );
}

class DeviceHeader extends StatelessWidget {
  const DeviceHeader({
    required this.connection,
    required this.status,
    this.lastSyncUtc,
    this.welcome = false,
    super.key,
  });

  final Connection connection;
  final DeviceStatus status;
  final DateTime? lastSyncUtc;
  final bool welcome;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final online = status.availability == DeviceAvailability.online;
    final checking = status.availability == DeviceAvailability.checking;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (welcome)
            Text(
              'Welcome',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          const SizedBox(height: 2),
          Text(
            connection.computerName,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: checking
                      ? colors.outline
                      : online
                          ? const Color(0xFF2E9D59)
                          : colors.error,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  checking
                      ? 'Checking connection…'
                      : online
                          ? _syncText(lastSyncUtc ?? connection.lastSeenUtc)
                          : 'Offline · ${_relativeTime(connection.lastSeenUtc, prefix: 'last seen ')}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ClipPoster extends StatelessWidget {
  const ClipPoster({required this.badge, this.selected = false, super.key});

  final String badge;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: colors.surfaceContainerHigh,
          child: Icon(Icons.videocam_outlined,
              size: 42, color: colors.onSurfaceVariant),
        ),
        if (selected) ColoredBox(color: colors.primary.withValues(alpha: 0.13)),
        Positioned(
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                badge,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        if (selected)
          Positioned(
            right: 8,
            top: 8,
            child: DecoratedBox(
              decoration:
                  BoxDecoration(color: colors.primary, shape: BoxShape.circle),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.check, color: Colors.white, size: 16),
              ),
            ),
          ),
      ],
    );
  }
}

String formatBytes(int value) {
  if (value < 1000) return '$value B';
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(0)} KB';
  if (value < 1000000000) return '${(value / 1000000).toStringAsFixed(1)} MB';
  return '${(value / 1000000000).toStringAsFixed(1)} GB';
}

String formatClipDate(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final sameDay = local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  final minute = local.minute.toString().padLeft(2, '0');
  if (sameDay) return 'Today · ${local.hour}:$minute';
  return '${local.day}.${local.month}.${local.year} · ${local.hour}:$minute';
}

String formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _syncText(DateTime? value) => value == null
    ? 'Connected · not synced yet'
    : 'Connected · ${_relativeTime(value, prefix: 'last sync ')}';

String _relativeTime(DateTime? value, {required String prefix}) {
  if (value == null) return '${prefix}unknown';
  final difference = DateTime.now().toUtc().difference(value.toUtc());
  if (difference.inMinutes < 1) return '${prefix}just now';
  if (difference.inHours < 1) return '$prefix${difference.inMinutes} min ago';
  if (difference.inDays < 1) return '$prefix${difference.inHours} hr ago';
  return '$prefix${difference.inDays} d ago';
}
