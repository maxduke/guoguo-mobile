import 'package:flutter/material.dart';

class PlayerNotice extends StatelessWidget {
  const PlayerNotice({
    super.key,
    required this.message,
    required this.action,
    this.secondaryAction,
  });

  final String message;
  final Widget action;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [action, ?secondaryAction],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
