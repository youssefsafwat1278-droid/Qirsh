import {
  Bell,
  Building2,
  FlaskConical,
  Gift,
  Inbox,
  LayoutDashboard,
  ListTree,
  Megaphone,
  Receipt,
  ScanText,
  Send,
  SlidersHorizontal,
  Store,
  TicketPercent,
  type LucideIcon,
} from "lucide-react";

export type NavItem = { href: string; label: string; icon: LucideIcon; description: string };
export type NavGroup = { group: string; items: NavItem[] };

/**
 * The Admin navigation registry — the single source for the sidebar, the
 * dashboard's quick-management grid and every page's section eyebrow.
 *
 * Server-safe on purpose (no "use client"), so Server Components can read it.
 *
 * It contains ONLY routes that exist under `app/(admin)/`. Every label is the
 * product word for the thing, never the table, RPC or feature-flag behind it.
 */
export const NAV: NavGroup[] = [
  {
    group: "نظرة عامة",
    items: [
      {
        href: "/dashboard",
        label: "الرئيسية",
        icon: LayoutDashboard,
        description: "ملخّص المستخدمين وحالة النظام",
      },
    ],
  },
  {
    group: "النمو والمكافآت",
    items: [
      {
        href: "/referrals",
        label: "الدعوات والمكافآت",
        icon: Gift,
        description: "قواعد الدعوة، المكافآت، ومراجعة التلاعب",
      },
      {
        href: "/campaigns",
        label: "الحملات",
        icon: Megaphone,
        description: "رسائل تظهر لشريحة محددة من المستخدمين",
      },
      {
        href: "/coupons",
        label: "العروض والكوبونات",
        icon: TicketPercent,
        description: "عروض الشركاء التي تظهر داخل التطبيق",
      },
      {
        href: "/merchants",
        label: "المتاجر والأسماء البديلة",
        icon: Store,
        description: "هوية المتاجر المعتمدة والأسماء التي تُطابَق بها رسائل البنوك",
      },
      {
        href: "/affiliate",
        label: "عروض الشركاء الواردة",
        icon: Inbox,
        description: "مراجعة ونشر العروض القادمة من شبكات الأفلييت",
      },
      {
        href: "/affiliate/conversions",
        label: "التحويلات والعمولة",
        icon: Receipt,
        description: "ما أبلغت به الشبكات من مبيعات وعمولة — لوحة إدارية فقط",
      },
      {
        href: "/announcements",
        label: "الإعلانات داخل التطبيق",
        icon: Bell,
        description: "لافتات وتنبيهات التحديث الإجباري",
      },
      {
        href: "/push",
        label: "إشعارات من قرش",
        icon: Send,
        description: "رسالة خدمة تصل كإشعار لمستخدمي السحابة",
      },
    ],
  },
  {
    group: "كتالوج البنوك والرسائل",
    items: [
      {
        href: "/banks",
        label: "البنوك",
        icon: Building2,
        description: "البنوك وأرقام المُرسِل الخاصة بها",
      },
      {
        href: "/parsers",
        label: "قواعد قراءة الرسائل",
        icon: ScanText,
        description: "القواعد التي تحوّل رسالة البنك إلى عملية",
      },
      {
        href: "/categories",
        label: "فئات المصروفات",
        icon: ListTree,
        description: "الفئات التي تُصنَّف عليها العمليات",
      },
      {
        href: "/parser-lab",
        label: "معمل القراءة",
        icon: FlaskConical,
        description: "جرّب رسالة بنك واعرف كيف يقرأها التطبيق",
      },
    ],
  },
  {
    group: "إعدادات النظام",
    items: [
      {
        href: "/flags",
        label: "إعدادات المزايا",
        icon: SlidersHorizontal,
        description: "تشغيل وإيقاف المزايا بدون تحديث التطبيق",
      },
    ],
  },
];

/** The flat list, for eyebrow / breadcrumb lookups. */
export const NAV_ITEMS: (NavItem & { group: string })[] = NAV.flatMap((g) =>
  g.items.map((i) => ({ ...i, group: g.group })),
);

export function activeNavItem(pathname: string): (NavItem & { group: string }) | null {
  return NAV_ITEMS.find((i) => pathname === i.href || pathname.startsWith(`${i.href}/`)) ?? null;
}
