import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/category_emoji.dart';
import '../../core/utils/category_palette.dart';
import '../../core/utils/lucide_icon_map.dart';
import '../../core/i18n/locale_provider.dart';
import '../../domain/entities/category_entity.dart';
import '../../engine/categorization/category.dart';
import '../../domain/entities/budget_entity.dart';

/// نموذج عرض تصنيف (جاهز للواجهة: أيقونة + لون).
class CategoryView {
  CategoryView(this.entity, {this.languageCode = 'ar'});

  final CategoryEntity entity;

  /// The UI language this view renders for. Resolved once, in
  /// [categoryCatalogProvider], rather than at each of the ~60 render sites.
  final String languageCode;

  String get id => entity.id;
  String get key => entity.key;
  /// The stored Arabic name, verbatim. Kept for the few places that genuinely
  /// mean "the Arabic name" rather than "the name to show".
  String get nameAr => entity.nameAr;

  /// The name to SHOW, in the active language.
  ///
  /// The local `categories` table has no `name_en` column at all — English
  /// names exist only in `remote_categories` — so every surface rendered the
  /// Arabic name regardless of locale. Category keys are stable, so a system
  /// category's English name is resolved from [Categories]; a user-created
  /// category has exactly one name, the one they typed, and keeps it.
  String get name {
    if (languageCode != 'en') return entity.nameAr;
    // `all_expenses` is a SYSTEM pseudo-category with a fixed id
    // (`__all_expenses__`), seeded ahead of the real ones and deliberately
    // absent from `Categories.all` so it never appears in a category picker.
    // That absence made it fall through to `nameAr`, so a whole-ledger budget
    // was labelled «كل المصروفات» in the English build — and unlike a
    // user-created category, this one cannot be renamed, so it is copy, not
    // data. `report_composer.dart` already special-cased it for the PDF; the
    // UI did not.
    if (entity.key == BudgetEntity.allExpensesCategoryKey) {
      return BudgetEntity.allExpensesNameEn;
    }
    final known = Categories.all.where((c) => c.key == entity.key);
    return known.isEmpty ? entity.nameAr : known.first.enName;
  }
  IconData get icon => lucideByName(entity.icon);

  /// المفتاح النصّي للأيقونة (نفس مفاتيح Lucide المخزَّنة في الـ DB).
  String get iconName => entity.icon;

  /// إيموجي التصنيف المقابل للمفتاح — يُرسَم عبر [CategoryGlyph].
  String get emoji => categoryEmoji(entity.icon);

  /// لون خلفية التايل الثابت (عميق ومكتوم) — بدل لون الـ DB المتغيّر.
  Color get tileColor => categoryTileColor(entity.icon);
  Color get color => Formatters.colorFromHex(entity.color);

  /// v2 category colour for the active theme (spec §2.1 palette); falls back
  /// to the stored [color] for a category the palette does not name.
  Color accent(Brightness brightness) =>
      categoryAccent(entity.key, brightness) ?? color;
}

/// كتالوج التصنيفات (id↔عرض، key↔عرض) — يُحمّل مرة من DB.
class CategoryCatalog {
  CategoryCatalog(List<CategoryEntity> categories, {this.languageCode = 'ar'})
      : all = _dedupeByKey(categories, languageCode) {
    for (final view in all) {
      _byId[view.id] = view;
      _byKey[view.key] = view;
    }
  }

  /// The language every [CategoryView] in this catalog renders in.
  ///
  /// The provider rebuilds the whole catalog when the language changes, and
  /// the tree keeps showing the PREVIOUS catalog until that future resolves.
  /// Exposed so a caller can tell a stale catalog from a current one instead
  /// of inferring it from the words.
  final String languageCode;

  // Guard against duplicate category rows in the DB (a duplicate key would crash
  // any DropdownButton built from `all`). Keep the first occurrence per key.
  static List<CategoryView> _dedupeByKey(
    List<CategoryEntity> categories,
    String languageCode,
  ) {
    final seen = <String>{};
    final result = <CategoryView>[];
    for (final entity in categories) {
      final view = CategoryView(entity, languageCode: languageCode);
      if (seen.add(view.key)) result.add(view);
    }
    return result;
  }

  final List<CategoryView> all;
  final Map<String, CategoryView> _byId = {};
  final Map<String, CategoryView> _byKey = {};

  CategoryView? byId(String? id) {
    if (id == null) return null;
    return _byId[id] ?? _byKey[id];
  }

  CategoryView? byKey(String? key) => key == null ? null : _byKey[key];
}

final categoryCatalogProvider = FutureProvider<CategoryCatalog>((ref) async {
  final categories = await ref.watch(categoryRepositoryProvider).getAll();
  // Watched, so switching language rebuilds every category label at once
  // instead of leaving stale names behind until the next data change.
  final locale = ref.watch(localeProvider);
  return CategoryCatalog(categories, languageCode: locale.languageCode);
});
