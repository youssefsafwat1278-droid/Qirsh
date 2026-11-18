import 'package:flutter/material.dart';

import '../../core/i18n/country_catalog.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/l10n_ext.dart';

/// Opens the searchable list of every country; resolves to the chosen one, or
/// null when dismissed. Used by onboarding and by Settings.
Future<IsoCountry?> showCountryPicker(BuildContext context, {String? current}) {
  return showGlassSheet<IsoCountry>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CountryPickerSheet(current: current),
  );
}

/// The currency to save for [country]: its default when the app can store
/// amounts in it; otherwise the user's explicit choice from
/// [storableCurrencies], or null when they dismiss the choice (save nothing).
Future<String?> currencyForCountry(
    BuildContext context, IsoCountry country) async {
  final storable = defaultCurrencyFor(country.code);
  if (storable != null) return storable;
  return showGlassSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CurrencyChoiceSheet(country: country),
  );
}

/// Asks for a currency from the storable set, saying honestly why.
class CurrencyChoiceSheet extends StatelessWidget {
  const CurrencyChoiceSheet({super.key, required this.country});

  final IsoCountry country;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final own = country.defaultCurrency;
    return SizedBox(
      key: const ValueKey('currency-choice-sheet'),
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.s2,
                AppSpacing.gutter, AppSpacing.s2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(l.currencyChoiceTitle,
                      style: AppTypography.sectionTitle(c.textPrimary)),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                    own == null
                        ? l.currencyChoiceNoCurrencyBody
                        : l.currencyChoiceUnsupportedBody(own),
                    style: AppTypography.body(c.textSecondary)
                        .copyWith(height: 1.5)),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: AppSpacing.s6),
              itemCount: storableCurrencies.length,
              itemBuilder: (context, index) {
                final code = storableCurrencies[index];
                return ListTile(
                  key: ValueKey('currency-$code'),
                  title: Text(Currency.codeWithLabel(context, code),
                      style: AppTypography.bodyStrong(c.textPrimary)),
                  onTap: () => Navigator.of(context).pop(code),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class CountryPickerSheet extends StatefulWidget {
  const CountryPickerSheet({super.key, this.current});

  final String? current;

  @override
  State<CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<CountryPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final language = Localizations.localeOf(context).languageCode;
    final results = searchCountries(_query, language);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l.countryPickerTitle,
                      style: AppTypography.sectionTitle(c.textPrimary)),
                  const SizedBox(height: AppSpacing.s2),
                  Text(l.countryCoverageNote,
                      key: const ValueKey('country-coverage-note'),
                      style: AppTypography.caption(c.textSecondary)
                          .copyWith(height: 1.5)),
                  const SizedBox(height: AppSpacing.s3),
                  TextField(
                    key: const ValueKey('country-search'),
                    autocorrect: false,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: l.countryPickerSearchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                ],
              ),
            ),
            Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(l.countryPickerNoResults,
                          style: AppTypography.body(c.textSecondary)))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s6),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final country = results[index];
                        final selected = country.code ==
                            widget.current?.trim().toUpperCase();
                        return ListTile(
                          key: ValueKey('country-${country.code}'),
                          selected: selected,
                          leading: ExcludeSemantics(
                              child: Text(country.flag,
                                  style: const TextStyle(fontSize: 24))),
                          title: Text(country.nameIn(language),
                              style: AppTypography.bodyStrong(c.textPrimary)),
                          subtitle: Text(
                              [
                                defaultCurrencyFor(country.code) ??
                                    l.countryCurrencyChooseNext,
                                if (country.hasVerifiedBankCoverage)
                                  l.countryCoverageTested,
                              ].join(' · '),
                              style: AppTypography.caption(c.textSecondary)),
                          trailing: selected
                              ? Icon(Icons.check_rounded, color: c.actionText)
                              : null,
                          onTap: () => Navigator.of(context).pop(country),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
