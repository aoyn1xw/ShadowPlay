import 'package:flutter/material.dart';

/// Flat media row. Large text stacks the preview above the file information.
class RecordingRow extends StatelessWidget {
  const RecordingRow(
      {required this.preview,
      required this.fileName,
      required this.metadata,
      required this.action,
      required this.onTap,
      this.selected = false,
      this.status,
      this.progress,
      this.downloading = false,
      super.key});
  final Widget preview;
  final String fileName;
  final String metadata;
  final Widget action;
  final VoidCallback? onTap;
  final bool selected;
  final String? status;
  final bool downloading;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final details =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 5),
      Text(metadata,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colors.onSurfaceVariant)),
      if (status != null) ...[
        const SizedBox(height: 5),
        Text(status!,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.error)),
      ],
      if (downloading) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(
            value: progress, semanticsLabel: 'Downloading $fileName'),
        const SizedBox(height: 4),
        Text(
            progress == null
                ? 'Downloading…'
                : 'Downloading ${(progress! * 100).round()}%',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    ]);
    final media = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AspectRatio(aspectRatio: 16 / 9, child: preview));
    return Column(children: [
      Semantics(
          selected: selected,
          child: Material(
            color: selected ? colors.primaryContainer : colors.surface,
            child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: LayoutBuilder(builder: (context, constraints) {
                    final stacked = constraints.maxWidth < 300 ||
                        MediaQuery.textScalerOf(context).scale(14) > 20;
                    if (stacked) {
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            media,
                            const SizedBox(height: 12),
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: details),
                                  const SizedBox(width: 8),
                                  action
                                ]),
                          ]);
                    }
                    return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 112, child: media),
                          const SizedBox(width: 14),
                          Expanded(child: details),
                          const SizedBox(width: 4),
                          action,
                        ]);
                  }),
                )),
          )),
      const Divider(indent: 20, endIndent: 20),
    ]);
  }
}

class LibraryHeading extends StatelessWidget {
  const LibraryHeading({required this.title, required this.detail, super.key});
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(detail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );
}
