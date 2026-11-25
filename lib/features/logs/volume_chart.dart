import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/log_repository.dart';

/// Bar chart of log volume over time. Tapping a bar zooms into its time window.
class VolumeChart extends StatelessWidget {
  const VolumeChart({super.key, required this.buckets, required this.onZoom});

  final List<VolumeBucket> buckets;
  final void Function(DateTime from, DateTime to) onZoom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (buckets.isEmpty) return const SizedBox.shrink();
    final maxCount = buckets.fold<int>(0, (m, b) => b.count > m ? b.count : m);
    final span = buckets.last.end.difference(buckets.first.start);
    final labelFmt = span.inHours <= 24
        ? DateFormat.Hm()
        : span.inDays <= 7
        ? DateFormat('EEE HH:mm')
        : DateFormat.MMMd();
    final tipFmt = span.inDays <= 1 ? DateFormat.Hm() : DateFormat('MMM d, HH:mm');
    final labelEvery = (buckets.length / 6).ceil().clamp(1, 1000);

    return LayoutBuilder(
      builder: (context, c) {
        final barWidth = ((c.maxWidth - 50) / buckets.length * 0.7).clamp(2.0, 22.0);
        return BarChart(
          BarChartData(
            maxY: maxCount == 0 ? 1 : maxCount * 1.15,
            alignment: BarChartAlignment.spaceBetween,
            gridData: FlGridData(
              drawVerticalLine: false,
              horizontalInterval: maxCount == 0 ? 1 : (maxCount * 1.15) / 3,
              getDrawingHorizontalLine: (_) => FlLine(color: scheme.outlineVariant, strokeWidth: 0.6),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: maxCount == 0 ? 1 : (maxCount * 1.15) / 3,
                  getTitlesWidget: (value, meta) {
                    if (value == meta.max) return const SizedBox.shrink();
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        NumberFormat.compact().format(value),
                        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                      ),
                    );
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  getTitlesWidget: (value, meta) {
                    final i = value.toInt();
                    if (i < 0 || i >= buckets.length || i % labelEvery != 0) {
                      return const SizedBox.shrink();
                    }
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        labelFmt.format(buckets[i].start),
                        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                      ),
                    );
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchCallback: (event, response) {
                if (event is FlTapUpEvent && response?.spot != null) {
                  final b = buckets[response!.spot!.touchedBarGroupIndex];
                  onZoom(b.start, b.end);
                }
              },
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => scheme.inverseSurface,
                tooltipPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                getTooltipItem: (group, _, rod, _) {
                  final b = buckets[group.x];
                  return BarTooltipItem(
                    '${NumberFormat.decimalPattern().format(b.count)} logs\n'
                    '${tipFmt.format(b.start)} – ${tipFmt.format(b.end)}\n'
                    'Tap to zoom in',
                    TextStyle(color: scheme.onInverseSurface, fontSize: 11),
                  );
                },
              ),
            ),
            barGroups: [
              for (var i = 0; i < buckets.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: buckets[i].count.toDouble(),
                      width: barWidth,
                      color: scheme.primary,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                    ),
                  ],
                ),
            ],
          ),
          duration: Duration.zero,
        );
      },
    );
  }
}
