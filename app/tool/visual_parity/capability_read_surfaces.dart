// Read-only view inputs. Platform permission APIs are never called here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';

class CaptureCapabilityReview extends StatelessWidget {
  const CaptureCapabilityReview({super.key, required this.mode});
  final String mode;

  @override
  Widget build(BuildContext context) => ProviderScope(
        overrides: [
          captureCapabilitiesProvider.overrideWith((ref) async =>
              CaptureCapabilities(
                receiveSmsDeclared: mode != 'Unavailable',
                hasReceiveSmsPermission: mode == 'On' || mode == 'GrantedOff',
                canUseAutomaticSmsCapture: mode == 'On' || mode == 'GrantedOff',
                isAutomaticSmsCaptureEnabled: mode == 'On',
              )),
        ],
        child: const SettingsScreen(page: SettingsPage.capture),
      );
}
