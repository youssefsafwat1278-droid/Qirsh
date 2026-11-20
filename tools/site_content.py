#!/usr/bin/env python3
"""Localised copy for the Qirsh public site.

Arabic is the default locale and lives at the site root; English lives under
/en/. Kept separate from `build_site.py` so the wording can be reviewed without
reading through markup.

EVERY factual claim here is traceable to the repository:

  the four privacy points   docs/legal/PRIVACY_POLICY.md §1, verbatim in English
                            and translated faithfully in Arabic
  capabilities              app/lib/features/{accounts,cards,budgets,goals,
                            capture,reports,subscriptions,reporting}
  3-decimal currencies      supabase/migrations/0091 + currency_scale.dart
  PDF typeface              app/lib/features/reporting/pdf/report_fonts.dart

No user counts, no ratings, no awards, no partners, no response-time promises.
"""

STRINGS = {
    "ar": {
        "lang": "ar", "dir": "rtl", "other": "en",
        "other_label": "EN", "other_title": "English",
        "site_title": "قِرش — إدارة مصاريفك بخصوصية",
        "site_desc": "قِرش يقرأ رسائل البنك اللي بتوصل لجوالك ويحوّلها لسجل خاص "
                     "لمصاريفك، على جهازك.",
        "skip": "تخطَّ إلى المحتوى",
        "menu": "القائمة",
        "nav_main": "التنقل الرئيسي",
        "nav": [("/", "الرئيسية"), ("/#features", "المزايا"),
                ("/privacy", "الخصوصية"), ("/terms", "الشروط"),
                ("/support", "الدعم")],
        "eyebrow": "قيد التجهيز للإصدار",
        "h1_a": "فلوسك، مسجَّلة ", "h1_accent": "بخصوصية", "h1_b": "، على جهازك.",
        "lede": "قِرش يقرأ رسائل البنك اللي جوالك بيستقبلها أصلاً، ويحوّلها لسجل "
                "واضح لمصاريفك — منظَّم، وقابل للبحث، وملكك أنت.",
        "cta_1": "شوف بيعمل إيه", "cta_2": "اقرأ سياسة الخصوصية",
        "hero_note": "المزامنة السحابية مقفولة افتراضياً. مفيش حاجة بتغادر جهازك "
                     "إلا لو شغّلتها بنفسك.",
        "shot_alt": "توضيح لواجهة قِرش: ملخص الرصيد مع أحدث العمليات.",
        "shot_month": "هذا الشهر", "shot_over": "نظرة عامة",
        "shot_bal": "إجمالي الرصيد", "shot_accounts": "عبر ٣ حسابات",
        "shot_chips": ["الرئيسي", "التوفير", "البطاقة"],
        "shot_rows": [("بقالة", "مُلتقَط من رسالة", "−٢٤٠٫٠٠", "out"),
                      ("اشتراك", "شهري", "−٤٥٫٠٠", "out"),
                      ("راتب", "إيداع", "+٨٬٢٠٠٫٠٠", "in")],
        "features_h": "قِرش بيعمل إيه",
        "features_p": "كل اللي تحت موجود في التطبيق فعلاً. مفيش هنا وصف لميزة لسه "
                      "مش موجودة.",
        "features": [
            ("inbox", "التقاط ذكي",
             "قِرش يقرأ رسائل البنك على جهازك — على أندرويد بعد ما تشغّل الالتقاط "
             "التلقائي وتمنح الإذن — ويحوّلها لعمليات، فمش محتاج تكتبها بإيدك. "
             "تقدر كمان تشارك أي رسالة أو تلزقها بنفسك."),
            ("list", "حسابات وبطاقات",
             "احتفظ بأكتر من حساب وبطاقة، كل واحد بعملته، والأرصدة تفضل منفصلة "
             "بدل ما تتجمع في رقم واحد."),
            ("target", "ميزانيات وأهداف",
             "حدّد ميزانية لكل فئة وأهداف ادّخار، وشوف تقدّمك عليها مع تسجيل "
             "المصاريف."),
            ("chart", "قراءة لمصاريفك",
             "التقارير بتقسّم الصرف حسب الفئة والفترة، وبتعرض إجمالي الصرف "
             "والمرتجعات والصافي كل واحد لوحده."),
            ("repeat", "فواتير واشتراكات",
             "تابع المدفوعات المتكررة، عشان التجديد يبقى حاجة متوقَّعة مش "
             "مفاجأة بعد ما تحصل."),
            ("doc", "تقارير تحتفظ بيها",
             "صدّر تقريرك PDF بنفس الخط المستخدَم في التطبيق، فالملف المصدَّر "
             "مطابق لللي شفته على الشاشة."),
        ],
        "privacy_h": "الخصوصية، بوضوح",
        "privacy_p": "دي النقط الأربعة اللي بتفتح بيها سياسة الخصوصية، من غير "
                     "تغيير. الوثيقة الكاملة بتشرح كل واحدة فيهم.",
        "privacy": [
            ("بياناتك المالية بتعيش على جهازك",
             "في قاعدة بيانات مشفَّرة بمفتاح محفوظ في الـ keychain بتاع الجهاز."),
            ("المزامنة السحابية مقفولة افتراضياً.",
             "وهي مقفولة، مفيش بيانات مالية بتغادر جهازك — وده مفروض عند كل "
             "اتصال بالشبكة، مش في شاشة الإعدادات بس."),
            ("الموديل اللي بيصنّف مصاريفك بيشتغل على جهازك.",
             "ولو شغّلت «التحليل الذكي» — مع المزامنة أو لوحده على الآيفون، "
             "ومقفول لحد ما توافق — نسخة متنضّفة من رسالة البنك ممكن تتبعت "
             "لسيرفراتنا ولـ Gemini من Google عشان تتقرا."),
            ("إحنا مابنبيعش بياناتك.",
             "مفيش ملف إعلاني بيتبني من عملياتك."),
        ],
        "privacy_link": "اقرأ سياسة الخصوصية كاملة",
        "faq_h": "أسئلة",
        "faq": [
            ("لازم أربط حسابي البنكي؟",
             "لأ. قِرش بيقرأ رسائل البنك اللي البنك بيبعتها لجوالك أصلاً — على "
             "أندرويد بعد ما تشغّل الالتقاط التلقائي وتمنح الإذن. مابيتصلش "
             "بالبنك، ومابيقراش إشعارات تطبيقات البنوك."),
            ("بياناتي المالية بتخرج من جوالي؟",
             "مش إلا لو شغّلت المزامنة السحابية. هي مقفولة افتراضياً، وطالما "
             "مقفولة مفيش بيانات مالية بتغادر الجهاز. التفاصيل الكاملة في سياسة "
             "الخصوصية."),
            ("الذكاء الاصطناعي بيشتغل فين؟",
             "تصنيف مصاريفك بيحصل على جهازك. قراءة الرسالة بـ Gemini من Google "
             "بتحصل بس لو شغّلت «التحليل الذكي» (مع المزامنة أو لوحده)، وبيتبعت نص "
             "متنضّف من أرقام البطاقات والحسابات والتليفونات."),
            ("إيه العملات المدعومة؟",
             "كل حساب بعملته، والمبالغ بتتخزَّن بدقة كاملة — بما فيها العملات "
             "بثلاث خانات عشرية زي الدينار الكويتي والبحريني."),
            ("التطبيق متاح للتحميل؟",
             "لسه لأ. هو قيد التجهيز للإصدار، والموقع هيتحدَّث أول ما يتاح."),
            ("أطلب المساعدة إزاي؟",
             'راسلنا على <a href="mailto:business@qirsh.site">business@qirsh.site</a>، '
             'أو شوف <a href="/support">صفحة الدعم</a>.'),
        ],
        "foot_desc": "تطبيق إدارة مصاريف بيقرأ رسائل البنك على جهازك ويحوّلها لسجل خاص "
                     "لمصاريفك.",
        "foot_product": "المنتج", "foot_legal": "قانوني ومساعدة",
        "foot_features": "المزايا", "foot_privacy_a": "نهجنا في الخصوصية",
        "foot_faq": "الأسئلة", "foot_privacy": "سياسة الخصوصية",
        "foot_terms": "شروط الاستخدام", "foot_support": "الدعم",
        "copyright": "قِرش ٢٠٢٦ ©",
        # support page
        "sup_title": "الدعم — قِرش",
        "sup_desc": "احصل على مساعدة في قِرش. راسلنا على business@qirsh.site.",
        "sup_h": "الدعم",
        "sup_p": "لو فيه حاجة مش شغالة، أو عندك سؤال عن طريقة تعامل قِرش مع "
                 "بياناتك، تواصل معانا. لو تقدر، اذكر نوع جهازك وإصدار التطبيق — "
                 "ده بيخلّي الرد أسرع.",
        "sup_email_l": "البريد",
        "sup_before": "قبل ما تكتب",
        "sup_before_p": "فيه سؤالين بيتكرروا كفاية إننا نجاوبهم هنا:",
        "sup_i1_b": "رسالة ما اتلقطتش.",
        "sup_i1": "قِرش بيقرأ الرسائل من المرسِلين اللي بيعرفهم. لو بنكك لسه مش "
                  "معروف، دي فجوة في الكتالوج مش عطل في جهازك — قوللنا اسم البنك "
                  "والدولة.",
        "sup_i2_b": "مبلغ ظاهر غلط.",
        "sup_i2": "ابعتلنا نص الرسالة بعد حذف أي بيانات شخصية. التعامل مع المبالغ "
                  "دقيق بالتصميم، فالرقم الغلط معناه قاعدة تحليل محتاجة إصلاح.",
        "sup_data_h": "بياناتك",
        "sup_data_p": 'طريقة تعامل قِرش مع معلوماتك، وإزاي تحذفها، موضحة في '
                      '<a href="/privacy">سياسة الخصوصية</a>. والشروط اللي '
                      'التطبيق متاح بموجبها في <a href="/terms">شروط الاستخدام</a>.',
        # legal shell
        "legal_note": "هذه الوثيقة معروضة بالإنجليزية، وهي النسخة القانونية "
                      "المعتمدة.",
        "privacy_title": "سياسة الخصوصية — قِرش",
        "terms_title": "شروط الاستخدام — قِرش",
    },

    "en": {
        "lang": "en", "dir": "ltr", "other": "ar",
        "other_label": "ع", "other_title": "العربية",
        "site_title": "Qirsh — private personal finance",
        "site_desc": "Qirsh reads the bank messages your phone already receives "
                     "and turns them into a private record of your spending.",
        "skip": "Skip to content",
        "menu": "Menu",
        "nav_main": "Main",
        "nav": [("/en/", "Home"), ("/en/#features", "Features"),
                ("/en/privacy", "Privacy"), ("/en/terms", "Terms"),
                ("/en/support", "Support")],
        "eyebrow": "In preparation for release",
        "h1_a": "Your money, recorded ", "h1_accent": "privately",
        "h1_b": ", on your device.",
        "lede": "Qirsh reads the bank messages your phone already receives and "
                "turns them into a clear record of your spending — organised, "
                "searchable, and yours.",
        "cta_1": "See what it does", "cta_2": "Read the privacy policy",
        "hero_note": "Cloud sync is off by default. Nothing leaves your device "
                     "unless you turn it on.",
        "shot_alt": "Illustration of the Qirsh app: a balance summary with "
                    "recent transactions.",
        "shot_month": "This month", "shot_over": "Overview",
        "shot_bal": "Total balance", "shot_accounts": "Across 3 accounts",
        "shot_chips": ["Main", "Savings", "Card"],
        "shot_rows": [("Groceries", "Captured from SMS", "−240.00", "out"),
                      ("Subscription", "Monthly", "−45.00", "out"),
                      ("Salary", "Deposit", "+8,200.00", "in")],
        "features_h": "What Qirsh does",
        "features_p": "Everything below is in the app today. Nothing here "
                      "describes a feature that does not exist yet.",
        "features": [
            ("inbox", "Smart capture",
             "Qirsh reads the bank SMS on your device — on Android, only after you "
             "turn on automatic capture and grant permission — and turns them "
             "into transactions, so you are not typing them in by hand. You can "
             "also share or paste a message yourself."),
            ("list", "Accounts and cards",
             "Keep multiple accounts and cards, each in its own currency, with "
             "balances kept separately rather than merged into one number."),
            ("target", "Budgets and goals",
             "Set budgets per category and savings goals, and see progress "
             "against them as spending is recorded."),
            ("chart", "Spending insights",
             "Reports break spending down by category and period, showing gross "
             "spending, refunds and the net figure separately."),
            ("repeat", "Bills and subscriptions",
             "Track recurring payments so a renewal is something you expected "
             "rather than something you discover afterwards."),
            ("doc", "Reports you can keep",
             "Export a report as a PDF rendered with the same typeface the app "
             "uses, so the export matches what you saw on screen."),
        ],
        "privacy_h": "Privacy, stated plainly",
        "privacy_p": "These are the four points the Privacy Policy opens with, "
                     "unchanged. The full document explains each of them.",
        "privacy": [
            ("Your financial data lives on your device",
             "in a database encrypted with a key held in the device keychain."),
            ("Cloud sync is off by default.",
             "With it off, no financial data leaves your device — enforced at "
             "every network call, not only in the settings screen."),
            ("The model that categorises your spending runs on your device.",
             "If you turn on Smart Analysis — with Cloud Sync, or on its own on "
             "iPhone, and off until you accept it — a sanitized copy of a bank "
             "message may be sent to our servers "
             "and to Google's Gemini API to help read it."),
            ("We do not sell your data.",
             "There is no advertising profile built from your transactions."),
        ],
        "privacy_link": "Read the full Privacy Policy",
        "faq_h": "Questions",
        "faq": [
            ("Do I have to connect my bank account?",
             "No. Qirsh reads the bank SMS your bank already sends to your phone — "
             "on Android, only after you turn on automatic capture and grant "
             "permission. It does not connect to your bank, and it does not "
             "read bank app notifications."),
            ("Does my financial data leave my phone?",
             "Not unless you turn cloud sync on. It is off by default, and with "
             "it off no financial data leaves the device. The full detail is in "
             "the Privacy Policy."),
            ("Where does the AI run?",
             "Categorising your spending happens on your device. Reading a "
             "message with Google's Gemini API happens only if you turn on Smart "
             "Analysis (with or without Cloud Sync), and the text is sanitized of card, account "
             "and phone numbers first."),
            ("Which currencies are supported?",
             "Each account carries its own currency, and amounts are stored "
             "exactly — including currencies with three decimal places, such as "
             "the Kuwaiti and Bahraini dinar."),
            ("Is Qirsh available to download?",
             "Not yet. It is in preparation for release. This site will be "
             "updated when it is available."),
            ("How do I get help?",
             'Email <a href="mailto:business@qirsh.site">business@qirsh.site</a>, '
             'or read the <a href="/en/support">support page</a>.'),
        ],
        "foot_desc": "A personal finance app that reads bank SMS on your device "
                     "and turns them into a private record of your spending.",
        "foot_product": "Product", "foot_legal": "Legal & help",
        "foot_features": "Features", "foot_privacy_a": "Privacy approach",
        "foot_faq": "FAQ", "foot_privacy": "Privacy Policy",
        "foot_terms": "Terms of Use", "foot_support": "Support",
        "copyright": "© 2026 Qirsh",
        "sup_title": "Support — Qirsh",
        "sup_desc": "Get help with Qirsh. Contact business@qirsh.site.",
        "sup_h": "Support",
        "sup_p": "If something is not working, or you have a question about how "
                 "Qirsh handles your data, please get in touch. Include your "
                 "device and the app version if you can — it makes the answer "
                 "faster.",
        "sup_email_l": "Email",
        "sup_before": "Before you write",
        "sup_before_p": "Two questions come up often enough to answer here:",
        "sup_i1_b": "A message was not captured.",
        "sup_i1": "Qirsh reads messages from senders it recognises. If your bank "
                  "is not recognised yet, that is a catalogue gap rather than a "
                  "fault on your device — tell us the bank and country.",
        "sup_i2_b": "An amount looks wrong.",
        "sup_i2": "Send the message text with any personal details removed. "
                  "Amount handling is exact by design, so a wrong figure is a "
                  "parsing rule to fix.",
        "sup_data_h": "Your data",
        "sup_data_p": 'How Qirsh handles your information, and how to delete it, '
                      'is described in the <a href="/en/privacy">Privacy Policy</a>. '
                      'The terms under which the app is offered are in the '
                      '<a href="/en/terms">Terms of Use</a>.',
        "legal_note": "",
        "privacy_title": "Privacy Policy — Qirsh",
        "terms_title": "Terms of Use — Qirsh",
    },
}
