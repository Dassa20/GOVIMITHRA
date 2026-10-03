// ============================================================
// DEA CONTACT SHEET — shared by the Home screen card.
// Shows the verified DEA offices; tapping a number opens the
// phone dialer (or copies the number if no dialer is available).
// The office list lives in dea_contacts.dart.
// ============================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dea_contacts.dart';

Future<void> callDeaNumber(BuildContext context, String number,
    {required bool si}) async {
  var ok = false;
  try {
    ok = await launchUrl(Uri(scheme: 'tel', path: number));
  } catch (_) {}
  if (!ok) {
    await Clipboard.setData(ClipboardData(text: number));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(si
              ? 'අංකය පිටපත් කළා: ${prettyPhone(number)}'
              : 'Number copied: ${prettyPhone(number)}')));
    }
  }
}

/// Opens the contact sheet. [preferredDistrict] puts that district's office first.
void showDeaContactSheet(BuildContext context,
    {required bool si, String? preferredDistrict}) {
  final mine = deaOffices
      .where((o) => preferredDistrict != null && o.district == preferredDistrict)
      .toList();
  final others = deaOffices
      .where((o) => o.district != null && !mine.contains(o))
      .toList();
  final head = deaOffices.where((o) => o.district == null).toList();
  final ordered = [...mine, ...others, ...head];

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
                si
                    ? 'අපනයන කෘෂිකර්ම දෙපාර්තමේන්තුව අමතන්න'
                    : 'Contact the Department of Export Agriculture',
                style: Theme.of(ctx)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                si
                    ? 'ඔබේ දිස්ත්‍රික්කයේ කාර්යාලයට අමතන්න.'
                    : 'Call the office for your district.',
                style: TextStyle(color: Colors.grey[700], fontSize: 13)),
            const SizedBox(height: 12),
            for (final o in ordered)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (mine.contains(o))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(si ? 'ඔබේ දිස්ත්‍රික්කය' : 'Your district',
                              style: TextStyle(
                                  color: Theme.of(ctx).colorScheme.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ),
                      Text(si ? o.nameSi : o.nameEn,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text(o.addressEn,
                          style:
                              TextStyle(color: Colors.grey[700], fontSize: 12)),
                      if (o.email != null)
                        Text(o.email!,
                            style: TextStyle(
                                color: Colors.grey[700], fontSize: 12)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final p in o.phones)
                          ActionChip(
                            avatar: const Icon(Icons.call, size: 16),
                            label: Text(prettyPhone(p)),
                            onPressed: () => callDeaNumber(ctx, p, si: si),
                          ),
                      ]),
                    ],
                  ),
                ),
              ),
            Text(
                si
                    ? 'කාර්යාල වේලාවන්හිදී (සඳුදා - සිකුරාදා) අමතන්න.'
                    : 'Please call during office hours (Monday to Friday).',
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ],
        ),
      ),
    ),
  );
}
