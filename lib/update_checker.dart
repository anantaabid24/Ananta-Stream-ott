import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Checks a remotely hosted JSON manifest and prompts users when a newer
/// Ananta OTT APK is available.
///
/// Uses the project's public GitHub version manifest and latest release page.
/// See UPDATE_SETUP.md for publishing the next version.
class AppUpdateChecker {
  AppUpdateChecker._();

  static const String manifestUrl =
      'https://raw.githubusercontent.com/Abidananta/Ananta-Stream-ott/refs/heads/main/version.json';
  static const String releaseUrl =
      'https://github.com/Abidananta/Ananta-Stream-ott/releases/latest';

  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final response = await http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return;

      final latestVersion = (data['version'] ?? '').toString().trim();
      final latestBuild = int.tryParse('${data['versionCode'] ?? 0}') ?? 0;
      final releaseNotes = (data['releaseNotes'] ?? 'Performance improvements and bug fixes.')
          .toString();
      final manifestDownloadUrl = (data['downloadUrl'] ?? '').toString().trim();
      final downloadUrl =
          manifestDownloadUrl.isNotEmpty ? manifestDownloadUrl : releaseUrl;
      if (latestVersion.isEmpty || !context.mounted) return;

      final packageInfo = await PackageInfo.fromPlatform();
      final installedBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      if (latestBuild <= installedBuild || !context.mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Ananta OTT update available'),
          content: SingleChildScrollView(
            child: Text(
              'A new version ($latestVersion) is available.\n\n'
              '$releaseNotes\n\n'
              'Open the download page to install the update. Android may ask '
              'you to confirm installation.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () async {
                final uri = Uri.tryParse(downloadUrl);
                if (uri == null ||
                    !(uri.scheme == 'https' || uri.scheme == 'http')) {
                  return;
                }
                Navigator.of(dialogContext).pop();
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: const Text('Download update'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Update checks must never prevent the app/player from starting.
    }
  }
}
