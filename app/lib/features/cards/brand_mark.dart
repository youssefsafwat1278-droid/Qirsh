import 'package:flutter/material.dart';
import '../../core/privacy/gated_network_image.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/category_tone.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_colors.dart';
import '../../engine/parser/payment_aggregators.dart';
import '../common/app_avatar.dart';
import '../settings/settings_providers.dart';

/// MALI-071n — whether merchant logos may be fetched from a third party.
///
/// Fetching a logo tells the remote host (the admin catalog CDN, or
/// img.logo.dev) which merchant the user is looking at, so it is gated on the
/// user's cloud-processing consent. Fails CLOSED: while the setting is loading,
/// errored, or unset, no remote request is made. Bundled SVGs and the letter
/// placeholder are always available offline regardless.
final remoteMerchantLogosAllowedProvider = Provider<bool>((ref) {
  return ref.watch(userSettingsProvider).maybeWhen(
        skipLoadingOnReload: true,
        data: (settings) => settings.cloudProcessingEnabled,
        orElse: () => false,
      );
});

/// علامة العلامة التجارية (Brand mark).
///
/// سلّم تقليل البيانات (MALI-071n): شعار SVG مرفق في الحزمة أولاً (محلي، بدون
/// شبكة) → ثم — بشرط موافقة المعالجة السحابية فقط — شعار الـ admin/DB ثم logo.dev
/// بالدومين العام المعروف (مش اسم التاجر الخام) → وإلا مربّع ملوّن بحرف. لو
/// الموافقة مرفوضة: لا أي طلب شبكة إطلاقاً — المرفق أو الحرف فقط.
class BrandMark extends ConsumerWidget {
  const BrandMark({
    super.key,
    required this.name,
    this.size = 44,
    this.logoUrl,
    this.fallback,
  });

  final String name;
  final double size;

  /// Shown instead of the generic first-letter tile when no real mark can be
  /// shown (no bundled SVG, no remote logo allowed or loaded, no curated brand
  /// colour). Transaction rows pass their category tile, so an unbranded
  /// merchant reads like every other categorised row — the prototype's
  /// `brandTile` → `catTile` rule.
  final Widget? fallback;

  /// Admin-managed brand logo URL (from the synced catalog). When present it's
  /// shown first; on load failure it falls back to the bundled SVG / letter mark.
  final String? logoUrl;

  /// علامات لها شعار SVG حقيقي مرفق في الحزمة (assets/brands/<slug>.svg).
  /// عشان تزوّد علامة: حط ملف الـ SVG في assets/brands/ وأضِف سطر هنا.
  // ملاحظة: الترتيب مهم — المفتاح الأطول/الأخص قبل الأعم (UBER EATS قبل UBER)
  // لأن build بترجّع أول تطابق بالاحتواء.
  static const Map<String, String> _brandSvgs = {
    'NETFLIX': 'netflix',
    'SPOTIFY': 'spotify',
    'YOUTUBE': 'youtube',
    'APPLE MUSIC': 'applemusic',
    'APPLE TV': 'appletv',
    'APPLE': 'apple',
    'ICLOUD': 'apple',
    'STARBUCKS': 'starbucks',
    'MCDONALD': 'mcdonalds',
    'KFC': 'kfc',
    'UBER EATS': 'ubereats',
    'UBEREATS': 'ubereats',
    'UBER': 'uber',
    'DELIVEROO': 'deliveroo',
    'AIRBNB': 'airbnb',
    'CARREFOUR': 'carrefour',
    'IKEA': 'ikea',
    'VODAFONE': 'vodafone',
    'ORANGE': 'orange',
    'DEEZER': 'deezer',
    'CLAUDE': 'claude',
    'COPILOT': 'githubcopilot',
    'GITHUB': 'github',
    'TIDAL': 'tidal',
    'PARAMOUNT': 'paramountplus',
    'CRUNCHYROLL': 'crunchyroll',
    'HBO': 'hbomax',
  };

  static const Map<String, (Color, String)> _brands = {
    'NETFLIX': (Color(0xFFE50914), 'N'),
    'SPOTIFY': (Color(0xFF1DB954), 'S'),
    'SHAHID': (Color(0xFF00A19A), 'ش'),
    'شاهد': (Color(0xFF00A19A), 'ش'),
    'OSN': (Color(0xFF1A1A1A), 'O'),
    'ICLOUD': (Color(0xFF3B82F6), 'i'),
    'APPLE': (Color(0xFF1A1A1A), ''),
    'STC': (Color(0xFF4F008C), 'STC'),
    'MOBILY': (Color(0xFF00A551), 'M'),
    'ZAIN': (Color(0xFF6F2C91), 'Z'),
    'YOUTUBE': (Color(0xFFFF0000), 'Y'),
    'AMAZON': (Color(0xFFFF9900), 'a'),
    'STARBUCKS': (Color(0xFF00704A), 'S'),
  };

  /// كل ملفات SVG الموجودة فعلاً في assets/brands/ (slugs lowercase، الأطول
  /// أولاً للمطابقة الصحيحة). تُملأ مرة واحدة عند الإقلاع من AssetManifest، فأي
  /// SVG تضيفه للمجلد يشتغل تلقائياً بدون تعديل كود.
  static List<String> _assetSlugs = const [];

  static void registerAssetSlugs(Iterable<String> slugs) {
    _assetSlugs = slugs.map((s) => s.toLowerCase()).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    _stableCache
        .clear(); // asset slugs feed _resolveSlug → invalidate the index
  }

  // B2-C — the brand catalogs (`_brandSvgs`, `_assetSlugs`, `_merchantDomains`,
  // `_brands`) are all fixed after startup, but matched by substring `.contains`,
  // so the resolution can't be a plain O(1) hash on the merchant name. Instead we
  // MEMOISE the whole stable resolution per merchant name: the first occurrence
  // scans the catalogs once, every later row with the same name is an O(1) map
  // hit. A transaction list has far fewer distinct merchants than rows, so this
  // turns the old O(rows × catalog) (scanned 2–3× per row across
  // _resolveSlug/logoDevUrlFor/hasBrand/build) into O(distinct merchants ×
  // catalog). Cleared when the asset catalog is (re)registered.
  static final Map<String, _StableBrand> _stableCache = {};
  static final RegExp _nonAlnum = RegExp('[^A-Z0-9]');

  /// Test hook: number of catalog computations (cache misses) since the last
  /// reset — proves repeated names do NOT re-scan the catalog.
  static int debugStableComputeCount = 0;

  static void debugResetBrandCache() {
    _stableCache.clear();
    debugStableComputeCount = 0;
  }

  static _StableBrand _stable(String name) {
    final cached = _stableCache[name];
    if (cached != null) return cached;
    debugStableComputeCount++;
    final upper = name.toUpperCase();
    // 1) bundled SVG slug — aggregators (bare payment gateways) never get one.
    String? slug;
    if (!PaymentAggregators.isAggregator(name)) {
      for (final entry in _brandSvgs.entries) {
        if (upper.contains(entry.key)) {
          slug = entry.value;
          break;
        }
      }
      if (slug == null) {
        final normalized = upper.replaceAll(_nonAlnum, '');
        for (final s in _assetSlugs) {
          if (s.length >= 4 && normalized.contains(s.toUpperCase())) {
            slug = s;
            break;
          }
        }
      }
    }
    // 2) logo.dev domain (matched regardless of aggregator status, as before).
    String? logoDevUrl;
    for (final entry in _merchantDomains.entries) {
      if (upper.contains(entry.key)) {
        logoDevUrl = 'https://img.logo.dev/${entry.value}'
            '?token=$_logoDevToken&size=128&format=png';
        break;
      }
    }
    // 3) coloured-letter fallback match.
    Color? letterColor;
    String? letterLabel;
    for (final entry in _brands.entries) {
      if (upper.contains(entry.key.toUpperCase())) {
        letterColor = entry.value.$1;
        letterLabel = entry.value.$2;
        break;
      }
    }
    final resolved = _StableBrand(
      slug: slug,
      logoDevUrl: logoDevUrl,
      letterColor: letterColor,
      letterLabel: letterLabel,
    );
    _stableCache[name] = resolved;
    return resolved;
  }

  /// يحدّد slug الشعار المناسب لاسم التاجر: الأسماء الصريحة (متعددة الكلمات/
  /// القصيرة) أولاً، ثم مطابقة تلقائية مع الملفات المرفقة (≥4 أحرف لتفادي
  /// التطابقات الخاطئة). (B2-C: memoised via [_stable].)
  static String? _resolveSlug(String name) => _stable(name).slug;

  /// يرجّع رابط شعار العلامة من خريطة (keyword عريض → URL) اللي بتيجي من الـ
  /// admin/DB، بمطابقة اسم التاجر بالاحتواء. null لو مفيش تطابق.
  ///
  /// NOT memoised: [logos] is the admin/DB catalog which can change on a catalog
  /// refresh (and is typically empty or very small). The O(rows × catalog)
  /// hotspot was the ~200-entry bundled `_merchantDomains` + asset slugs, which
  /// are now memoised via [_stable].
  static String? logoFor(String name, Map<String, String> logos) {
    if (logos.isEmpty) return null;
    final upper = name.toUpperCase();
    for (final entry in logos.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// توكن logo.dev العام (publishable key — مصمّم ليُوضع في العميل، مش سر).
  static const String _logoDevToken = 'pk_VosyOg4TQym3BGOMQEjULQ';

  /// تجار إقليميون (خليج/مصر) مش موجودين في مجموعات الأيقونات المفتوحة، فنجيب
  /// شعارهم من logo.dev بالدومين عبر الشبكة (مطابقة بالاحتواء — الأطول/الأخص
  /// أولاً). أي تاجر له SVG مرفق بيكسب أولاً (أوفلاين)؛ ده للباقي فقط.
  static const Map<String, String> _merchantDomains = {
    'THE CHEFZ': 'thechefz.com',
    'AL TAZAJ': 'altazaj.com',
    'MAMA NOURA': 'mamanoura.com.sa',
    'COOK DOOR': 'cookdoor.com',
    'MAESTRO PIZZA': 'maestropizza.com',
    'HALF MILLION': 'halfmillion.com.sa',
    'DR CAFE': 'drcafe.com',
    'SHARAF DG': 'sharafdg.com',
    'MAX FASHION': 'maxfashion.com',
    'HOME CENTRE': 'homecentre.com',
    'GOLDS GYM': 'goldsgym.com',
    'FITNESS TIME': 'fitnesstime.com.sa',
    'WATCH IT': 'watchit.com',
    'TALABAT': 'talabat.com',
    'ELMENUS': 'elmenus.com',
    'BREADFAST': 'breadfast.com',
    'HUNGERSTATION': 'hungerstation.com',
    'MRSOOL': 'mrsool.co',
    'JAHEZ': 'jahez.net',
    'ALBAIK': 'albaik.com',
    'HERFY': 'herfy.com',
    'KUDU': 'kudu.com.sa',
    'SHAWARMER': 'shawarmer.com',
    'KEBABJI': 'kebabji.com',
    'ZOOBA': 'zooba.com',
    'BARNS': 'barnscoffee.com',
    'SPINNEYS': 'spinneys.com',
    'SEOUDI': 'seoudisupermarket.com',
    'KAZYON': 'kazyon.com',
    'PANDA': 'panda.com.sa',
    'OTHAIM': 'othaimmarkets.com',
    'DANUBE': 'danube.sa',
    'TAMIMI': 'tamimimarkets.com',
    'LULU': 'luluhypermarket.com',
    'BINDAWOOD': 'bindawoodstores.com',
    'NESTO': 'nesto.com',
    'RABBIT': 'rabbitmart.com',
    'JARIR': 'jarir.com',
    'BTECH': 'btech.com',
    'JUMIA': 'jumia.com',
    'SHEIN': 'shein.com',
    'NAMSHI': 'namshi.com',
    'CENTREPOINT': 'centrepointstores.com',
    'SPLASH': 'splashfashions.com',
    'BABYSHOP': 'babyshopstores.com',
    'REDTAG': 'redtagfashion.com',
    'TRADELINE': 'tradeline.me',
    'CAREEM': 'careem.com',
    'SWVL': 'swvl.com',
    'INDRIVE': 'indrive.com',
    'JEENY': 'jeeny.me',
    'SAPTCO': 'saptco.com.sa',
    'ARAMCO': 'aramco.com',
    'PETROMIN': 'petromin.com',
    'SASCO': 'sasco.com.sa',
    'ADNOC': 'adnoc.ae',
    'ENOC': 'enoc.com',
    'EMARAT': 'emarat.ae',
    'ETISALAT': 'etisalat.ae',
    'MOBILY': 'mobily.com.sa',
    'OOREDOO': 'ooredoo.com',
    'DEWA': 'dewa.gov.ae',
    'BATELCO': 'batelco.com',
    'NAHDI': 'nahdionline.com',
    'ALDAWAA': 'al-dawaa.com',
    'ELEZABY': 'elezabypharmacy.com',
    'VEZEETA': 'vezeeta.com',
    'DALLAH': 'dallah-hospital.com',
    'MAGRABI': 'magrabi.com',
    'ANGHAMI': 'anghami.com',
    'SHAHID': 'shahid.net',
    'SAUDIA': 'saudia.com',
    'FLYNAS': 'flynas.com',
    'FLYADEAL': 'flyadeal.com',
    'EGYPTAIR': 'egyptair.com',
    'ALMOSAFER': 'almosafer.com',
    'TAJAWAL': 'tajawal.com',
    'ETIHAD': 'etihad.com',
    'SEPHORA': 'sephora.com',
    'NSTYLE': 'nstyleintl.com',
    'LEEJAM': 'leejam.com.sa',
    'BODYMASTERS': 'bodymasters.com.sa',
    'TABBY': 'tabby.ai',
    'TAMARA': 'tamara.co',
    'INSTAPAY': 'instapay.eg',
    'TAWUNIYA': 'tawuniya.com',
    'MEDGULF': 'medgulf.com.sa',
    // ── تغطية موسّعة: باقي تجار الـ seeds (متعدد الكلمات أولاً) ──
    'BUFFALO BURGER': 'buffaloburger.com',
    'TEXAS CHICKEN': 'texaschicken.com',
    'LITTLE CAESARS': 'littlecaesars.com',
    'PAPA JOHNS': 'papajohns.com',
    'SHAKE SHACK': 'shakeshack.com',
    'TIM HORTONS': 'timhortons.com',
    'SECOND CUP': 'secondcup.com',
    'GLORIA JEANS': 'gloriajeans.com',
    'UNION COOP': 'unioncoop.ae',
    'AL MAYA': 'almaya.ae',
    'HYPER ONE': 'hyperone.com.eg',
    'REEL CINEMAS': 'reelcinemas.com',
    'FITNESS FIRST': 'fitnessfirst.com',
    'DAR AL FOUAD': 'daralfouad.org',
    'SAUDI GERMAN': 'sghgroup.com.sa',
    'AL HABIB': 'hmg.com',
    'BRITISH COUNCIL': 'britishcouncil.org',
    'INSTASHOP': 'instashop.com',
    'MOMEN': 'momen.com',
    'HARDEES': 'hardees.com',
    'COSTA': 'costacoffee.com',
    'CARIBOU': 'cariboucoffee.com',
    'DUNKIN': 'dunkindonuts.com',
    'CILANTRO': 'cilantro.com.eg',
    'JOFFREYS': 'joffreys.com',
    'ARABICA': 'arabica.coffee',
    'CHOITHRAMS': 'choithrams.com',
    'ALMEERA': 'almeera.com.qa',
    'GRANDIOSE': 'grandiose.ae',
    'GOURMET': 'gourmetegypt.com',
    'RAGAB': 'ragabsons.com',
    'VIRGIN': 'virginmegastore.com',
    'AMAZON': 'amazon.com',
    'AMZN': 'amazon.com',
    'TEMU': 'temu.com',
    'ADOBE': 'adobe.com',
    'MICROSOFT': 'microsoft.com',
    'BOLT': 'bolt.eu',
    'YANGO': 'yango.com',
    'TOYOU': 'toyou.io',
    'TOTALENERGIES': 'totalenergies.com',
    'MOBIL': 'mobil.com',
    'STC': 'stc.com.sa',
    'ZAIN': 'zain.com',
    'MOUWASAT': 'mouwasat.com',
    'ANDALUSIA': 'andalusiagroup.net',
    'CLEOPATRA': 'cleopatrahospitals.com',
    'DISNEY': 'disneyplus.com',
    'VOX': 'voxcinemas.com',
    'MUVI': 'muvicinemas.com',
    'CINEPOLIS': 'cinepolis.com',
    'FLYDUBAI': 'flydubai.com',
    'WEGO': 'wego.com',
    'AGODA': 'agoda.com',
    'BOOKING': 'booking.com',
    'SKYSCANNER': 'skyscanner.net',
    'FACES': 'faces.com',
    'BUPA': 'bupa.com.sa',
    'NAGWA': 'nagwa.com',
    'ORMAN': 'orman.org.eg',
    'EHSAN': 'ehsan.sa',
    // ── اشتراكات وفواتير وأقساط إضافية ──
    'YOUTUBE PREMIUM': 'youtube.com',
    'AMAZON PRIME': 'primevideo.com',
    'OSN': 'osnplus.com',
    'STARZPLAY': 'starzplay.com',
    'JAWWY': 'jawwy.sa',
    'WEYYAK': 'weyyak.com',
    'MIDJOURNEY': 'midjourney.com',
    'CHATGPT': 'openai.com',
    'TOD': 'tod.tv',
    'VIU': 'viu.com',
    'VALU': 'valu.com.eg',
    'SOUHOOLA': 'souhoola.com',
    'HALAN': 'halan.com',
    'FORSA': 'forsa.com',
    'PERPLEXITY': 'perplexity.ai',
    'BEIN': 'bein.com',
    'XBOX': 'xbox.com',
    'LINKEDIN': 'linkedin.com',
    'MADFU': 'madfu.com.sa',
    'EMKAN': 'emkan.com.sa',
    'SYMPL': 'sympl.ai',
    'CONTACT': 'contact.eg',
    'AMAN': 'aman.com.eg',
    'SHAHRY': 'shahry.com',
    'KHAZNA': 'khazna.app',
    'POSTPAY': 'postpay.io',
    'CASHEW': 'cashewpayments.com',
    // أسماء عربية شائعة → نفس الدومين
    'بنده': 'panda.com.sa',
    'العثيم': 'othaimmarkets.com',
    'النهدي': 'nahdionline.com',
    'الدواء': 'al-dawaa.com',
    'كريم': 'careem.com',
    'طلبات': 'talabat.com',
    'مرسول': 'mrsool.co',
    'جاهز': 'jahez.net',
    'البيك': 'albaik.com',
    'كازيون': 'kazyon.com',
    'العزبي': 'elezabypharmacy.com',
    'شاهد': 'shahid.net',
    'المسافر': 'almosafer.com',
  };

  /// يبني رابط شعار logo.dev لاسم التاجر لو ليه دومين معروف، وإلا null.
  /// (B2-C: memoised via [_stable].)
  static String? logoDevUrlFor(String name) => _stable(name).logoDevUrl;

  /// هل [name] علامة معروفة (شعار حقيقي أو مربّع ملوّن مميّز)؟ تُستخدم لتقرّر
  /// إظهار شعار العلامة بدل أيقونة التصنيف في صف العملية. (B2-C: memoised — a
  /// single map hit instead of three catalog scans.)
  static bool hasBrand(String name) => _stable(name).hasBrand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowRemote = ref.watch(remoteMerchantLogosAllowedProvider);

    // 1) شعار SVG مرفق (محلي، بدون شبكة) — أول السلّم دائماً.
    final slug = _resolveSlug(name);
    final edge = AppAvatar.logoEdge(context);
    if (slug != null) return _svgMark(slug, edge);

    // 2) الشعارات البعيدة تتطلّب موافقة المعالجة السحابية. مرفوضة → مفيش أي طلب.
    //
    // While a remote logo loads, the tile shows the merchant's MONOGRAM (never
    // the category icon), and the logo crossfades in over it. A failed load
    // keeps the monogram — the next rung of the ladder (logo.dev) shows the
    // same monogram while it tries — so the tile never hard-swaps.
    if (allowRemote) {
      final monogram = _monogram(context);
      final logoDevUrl = logoDevUrlFor(name);
      final logoDevTile = logoDevUrl == null
          ? null
          : _networkLogo(logoDevUrl, edge,
              placeholder: monogram, fallback: monogram);
      if (logoUrl != null && logoUrl!.isNotEmpty) {
        return _networkLogo(logoUrl!, edge,
            placeholder: monogram, fallback: logoDevTile ?? monogram);
      }
      if (logoDevTile != null) return logoDevTile;
    }

    // 3) بديل بدون شبكة.
    return _letterMark();
  }

  Widget _svgMark(String slug, BorderSide edge) {
    return Container(
      width: size,
      height: size,
      // The mark fills the tile: contain with ≤12% padding.
      padding: EdgeInsets.all(size * 0.12),
      decoration: ShapeDecoration(
        color: slug == 'sony' ? AppBrandBlue.deep : Colors.white,
        shape: AppAvatar.shapeFor(size,
            side: slug == 'sony' ? BorderSide.none : edge),
      ),
      child: SvgPicture.asset(
        'assets/brands/$slug.svg',
        fit: BoxFit.contain,
      ),
    );
  }

  /// شعار من الشبكة يملا المربّع: [placeholder] تحته لحد ما يوصل، ثم fade
  /// (أو ظهور فوري لو كان في الكاش)، و[fallback] لو فشل التحميل.
  Widget _networkLogo(String url, BorderSide edge,
      {required Widget placeholder, required Widget fallback}) {
    return _NetworkLogoTile(
      key: ValueKey<String>('brandLogo:$url'),
      provider: GatedNetworkImage(url),
      size: size,
      edge: edge,
      placeholder: placeholder,
      fallback: fallback,
    );
  }

  /// Icon keys whose design-family tones (bg + ink, per theme) give the
  /// monogram its calm tint. Income green is left out so a merchant initial
  /// never reads as money in.
  static const List<String> _monogramTones = [
    'cake', // food
    'plane', // move
    'house', // bill
    'gift', // shop
    '', // neutral (qirsh blue wash)
  ];

  /// FNV-1a over the name's code units — stable across runs and builds, so a
  /// merchant keeps the same tint everywhere (unlike `String.hashCode`).
  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// The loading placeholder: the merchant's first grapheme on a calm tinted
  /// tile whose hue is derived from a stable hash of the name.
  Widget _monogram(BuildContext context) {
    final trimmed = name.trim();
    final glyph =
        trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
    final tone = categoryTone(
      _monogramTones[_stableHash(trimmed.toUpperCase()) % _monogramTones.length],
      Theme.of(context).brightness,
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: tone.background,
        shape: AppAvatar.shapeFor(size),
      ),
      child: Text(
        glyph,
        style: AppTypography.title2(tone.ink).copyWith(
          fontSize: size * 0.40,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }

  Widget _letterMark() {
    // B2-C — the _brands match is memoised in _stable; the first-character
    // fallback still derives from this instance's name.
    final resolved = _stable(name);
    if (resolved.letterColor == null && fallback != null) return fallback!;
    final firstChar = name.isNotEmpty ? name.characters.first : '?';
    final Color color = resolved.letterColor ?? const Color(0xFF0A2540);
    final String label = (resolved.letterLabel == null)
        ? firstChar
        : (resolved.letterLabel!.isEmpty ? firstChar : resolved.letterLabel!);

    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: color,
        shape: AppAvatar.shapeFor(size),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * (label.length > 2 ? 0.32 : 0.46),
        ),
      ),
    );
  }
}

/// The memoised, stable-catalog resolution for one merchant name (B2-C). Built
/// once per distinct name; a coloured-letter match sets [letterColor] (and
/// [letterLabel]: empty string = "use the name's first character").
class _StableBrand {
  const _StableBrand({
    this.slug,
    this.logoDevUrl,
    this.letterColor,
    this.letterLabel,
  });

  final String? slug;
  final String? logoDevUrl;
  final Color? letterColor;
  final String? letterLabel;

  bool get hasBrand =>
      slug != null || logoDevUrl != null || letterColor != null;
}

/// A remote merchant logo that FILLS its tile.
///
/// - Square-ish logos (aspect 0.8–1.25) are drawn full-bleed (`cover`); wide
///   wordmarks, or a logo whose size is not known yet, are contained with a
///   10% inset on white.
/// - Until the first frame arrives, [placeholder] (the merchant monogram)
///   shows; the logo then crossfades in over ~300ms. A logo already in the
///   image cache paints on the first frame with no fade, so cached logos never
///   animate. Reduce Motion skips the fade.
/// - On a load error, [fallback] replaces the tile.
class _NetworkLogoTile extends StatefulWidget {
  const _NetworkLogoTile({
    super.key,
    required this.provider,
    required this.size,
    required this.edge,
    required this.placeholder,
    required this.fallback,
  });

  final ImageProvider provider;
  final double size;
  final BorderSide edge;
  final Widget placeholder;
  final Widget fallback;

  @override
  State<_NetworkLogoTile> createState() => _NetworkLogoTileState();
}

class _NetworkLogoTileState extends State<_NetworkLogoTile> {
  ImageStream? _stream;
  late final ImageStreamListener _listener =
      ImageStreamListener(_onImage, onError: _onError);

  /// Width / height of the decoded logo, once known.
  double? _aspect;
  bool _resolving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_NetworkLogoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      _aspect = null;
      _resolve();
    }
  }

  /// Listens to the same (cached) image stream the [Image] below uses — one
  /// request, shared — only to learn the logo's aspect ratio.
  void _resolve() {
    final stream =
        widget.provider.resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) {
      return;
    }
    _stream?.removeListener(_listener);
    _stream = stream;
    _resolving = true;
    stream.addListener(_listener);
    _resolving = false;
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    final width = info.image.width;
    final height = info.image.height;
    info.dispose();
    final aspect = height == 0 ? 1.0 : width / height;
    if (aspect == _aspect) return;
    if (_resolving || !mounted) {
      _aspect = aspect; // cached: known before the first build.
    } else {
      setState(() => _aspect = aspect);
    }
  }

  // The [Image] below shows [_NetworkLogoTile.fallback] on error; this
  // listener only has to mark the error as handled.
  void _onError(Object error, StackTrace? stackTrace) {}

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final aspect = _aspect;
    final fills = aspect != null && aspect >= 0.8 && aspect <= 1.25;
    final fade = (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
        ? Duration.zero
        : AppMotion.moderate;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.placeholder,
          Image(
            image: widget.provider,
            fit: fills ? BoxFit.cover : BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => widget.fallback,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              final plate = Container(
                padding: EdgeInsets.all(fills ? 0 : size * 0.10),
                clipBehavior: Clip.antiAlias,
                decoration: ShapeDecoration(
                  color: Colors.white,
                  shape: AppAvatar.shapeFor(size),
                ),
                foregroundDecoration: ShapeDecoration(
                  shape: AppAvatar.shapeFor(size, side: widget.edge),
                ),
                child: child,
              );
              // Cached → painted on the first frame, no animation.
              if (wasSynchronouslyLoaded) return plate;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: fade,
                curve: Curves.easeOut,
                child: plate,
              );
            },
          ),
        ],
      ),
    );
  }
}
