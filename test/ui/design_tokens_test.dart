import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/app/design_tokens.dart';
import 'package:quax/app/theme.dart';

void main() {
  test('Should keep the monochrome layout on one 4dp scale', () {
    expect(
      AppSpace.xs,
      4,
      reason: 'The micro gap and the radius base must agree',
    );
    expect(AppSpace.sm, 8, reason: 'Tight related items share one gap');
    expect(
      AppSpace.md,
      12,
      reason: 'Card rows and button groups share one gap',
    );
    expect(
      AppSpace.lg,
      16,
      reason: 'The screen gutter is what makes every edge line up',
    );
    expect(AppSpace.xl, 24, reason: 'Sections breathe without drifting to 32+');
  });

  test('Should keep one closed radius family', () {
    expect(
      [AppRadius.xs, AppRadius.sm, AppRadius.md, AppRadius.lg, AppRadius.xl],
      [4.0, 8.0, 12.0, 16.0, 24.0],
      reason:
          'A stray 6/14/28 radius is what makes two cards look almost aligned',
    );
  });

  test('Should keep the dark palette monochrome', () {
    final scheme = AppPalette.scheme(
      Brightness.dark,
      seed: AppPalette.graphiteSeed,
      trueBlack: true,
    );

    expect(
      scheme.primary,
      const Color(0xFFE8E8EA),
      reason: 'A hue creeping back into primary is how the old salmon/blue theme returns',
    );
    expect(
      scheme.primaryContainer,
      const Color(0xFF2A2A2F),
      reason: 'The avatar and selected controls must stay neutral',
    );
    expect(
      scheme.surface,
      const Color(0xFF000000),
      reason: 'AMOLED black still owns the canvas',
    );
    expect(
      scheme.surfaceContainerLow,
      const Color(0xFF0B0B0C),
      reason: 'Cards must stay one step above the canvas instead of merging into it',
    );
  });

  test('Should give every filled button the same height and radius', () {
    final theme = buildAppTheme(
      brightness: Brightness.dark,
      seedColor: AppPalette.graphiteSeed,
      trueBlack: true,
      disableAnimations: false,
    );
    final style = theme.filledButtonTheme.style!;

    expect(
      style.minimumSize?.resolve({}),
      const Size(0, 44),
      reason: 'Buttons in one row must line up on the same baseline',
    );
    expect(
      style.shape?.resolve({}),
      const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      reason: 'A single button radius is what keeps the action row symmetrical',
    );
  });

  test('Should keep button and media sizes predictable', () {
    expect(
      AppSize.button,
      44,
      reason: 'Secondary buttons stay compact but tappable',
    );
    expect(
      AppSize.buttonLarge,
      48,
      reason: 'Primary and onboarding actions are thumb-sized',
    );
    expect(AppSize.touch, 48, reason: 'Every icon control keeps a 48dp target');
    expect(
      AppSize.mediaMaxViewportFraction,
      0.6,
      reason: 'A portrait clip must not push the post context off screen',
    );
    expect(
      AppRadius.mdAll,
      const BorderRadius.all(Radius.circular(12)),
      reason: 'Buttons and inputs share the same corner so a row reads as one system',
    );
  });
}
