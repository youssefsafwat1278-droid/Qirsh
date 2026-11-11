import 'package:flutter/painting.dart';
import 'dart:ui' show Brightness;

/// لون خلفية ثابت (عميق ومكتوم) لتايل كل تصنيف — بدل لون الـ DB المتغيّر.
///
/// المفتاح النصّي كما يُخزَّن في الـ DB (نفس مفاتيح Lucide). القيمتان المرجعيتان
/// من طلب التصميم: التسوّق كحلي `#17264D`، الأكل بنّي `#3A2A13`؛ وباقي التصنيفات
/// درجات عميقة على نفس الطابع كي يبقى الشكل متناسقًا.
Color categoryTileColor(String key) {
  switch (key) {
    // الأكل والمشروبات — بنّي عميق (مرجع الطلب)
    case 'utensils-crossed':
      return const Color(0xFF3A2A13);
    case 'coffee':
      return const Color(0xFF2C1E12);
    // التسوّق — كحلي عميق (مرجع الطلب)
    case 'shopping-basket':
      return const Color(0xFF17264D);
    case 'shopping-bag':
      return const Color(0xFF2B1E45);
    // مواصلات ووقود
    case 'car-taxi-front':
      return const Color(0xFF3A2E0E);
    case 'fuel':
      return const Color(0xFF123330);
    // فواتير وتحويلات
    case 'receipt-text':
      return const Color(0xFF242832);
    case 'repeat':
      return const Color(0xFF1B2342);
    case 'arrow-left-right':
      return const Color(0xFF1F2A33);
    case 'wallet-cards':
      return const Color(0xFF15263A);
    case 'banknote':
      return const Color(0xFF15331E);
    // صحة وتعليم
    case 'heart-pulse':
      return const Color(0xFF3A171B);
    case 'shield-check':
      return const Color(0xFF12302A);
    case 'graduation-cap':
      return const Color(0xFF14233B);
    // ترفيه وسفر
    case 'clapperboard':
      return const Color(0xFF2C1740);
    case 'plane':
      return const Color(0xFF132943);
    case 'hotel':
      return const Color(0xFF291B34);
    // منزل وصيانة
    case 'house':
      return const Color(0xFF2E2416);
    case 'wrench':
      return const Color(0xFF262B31);
    case 'cigarette':
      return const Color(0xFF2A2320);
    // شخصي ومناسبات
    case 'gift':
      return const Color(0xFF3A1531);
    case 'baby':
      return const Color(0xFF33192A);
    case 'scissors':
      return const Color(0xFF33182A);
    case 'dumbbell':
      return const Color(0xFF3A2113);
    case 'dog':
      return const Color(0xFF2E2113);
    case 'cake':
      return const Color(0xFF321533);
    case 'heart-handshake':
      return const Color(0xFF123331);
    case 'piggy-bank':
      return const Color(0xFF331C24);
    // عام/غير مصنّف
    case 'shapes':
    default:
      return const Color(0xFF23262E);
  }
}

/// Calm Capital v2 category palette (spec §2.1). None equals the semantic
/// green/red; dark ≥3:1 on #121317, light ≥3:1 on white. Keyed by the stable
/// category KEY (`'shopping'`, `'restaurants'`…). Returns null for a key the
/// palette does not name, so a user-created category keeps its own colour.
Color? categoryAccent(String key, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  const named = <String, List<int>>{
    'shopping': [0xFFA78BFA, 0xFF7C4DDB],
    'groceries': [0xFF5EC8E5, 0xFF0E94B8],
    'restaurants': [0xFFFF8A5B, 0xFFE0622B],
    'cafes': [0xFFD4A373, 0xFF9C6B3F],
    'transport': [0xFF6E9BFF, 0xFF2F6BE0],
    'subscriptions': [0xFFF472B6, 0xFFD0398A],
  };
  final hit = named[key];
  if (hit != null) return Color(dark ? hit[0] : hit[1]);
  const overflowDark = [0xFF9DB9FF, 0xFFC4B5FD, 0xFF7DD3C0, 0xFFE4BA41];
  const overflowLight = [0xFF5B7FD6, 0xFF8E7AD8, 0xFF2E9C87, 0xFFB8891A];
  const systemKeys = [
    'fuel', 'bills', 'health', 'education', 'entertainment', 'transfers',
    'cash', 'travel', 'gifts', 'kids', 'home', 'maintenance', 'smoking',
    'fitness', 'beauty', 'charity', 'pets', 'insurance', 'income', 'other',
  ];
  final i = systemKeys.indexOf(key);
  if (i < 0) return null;
  return Color((dark ? overflowDark : overflowLight)[i % 4]);
}
