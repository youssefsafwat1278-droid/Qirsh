import 'package:flutter/widgets.dart';

/// UX-09 / SP-10: true above 1.25x text — from there a one-line label wraps
/// (or a row stacks) instead of being cut off with an ellipsis. The same
/// threshold the stacked layouts use (`scale(16) > 20`).
bool isLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(16) > 20;

/// `maxLines` for a label that keeps [normal] lines at regular sizes and
/// wraps freely at large text, where cutting it would hide its meaning.
///
/// A generous finite count rather than null: a `Text` with an ellipsis
/// overflow and null `maxLines` is laid out as ONE line, so null would still
/// cut it.
int linesUnlessLargeText(BuildContext context, int normal) =>
    isLargeText(context) ? 50 : normal;
