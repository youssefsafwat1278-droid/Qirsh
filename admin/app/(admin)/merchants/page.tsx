import Link from "next/link";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { HelpNote, PageHeader } from "@/components/ui/primitives";
import { MerchantsManager, type AliasRow, type MerchantRow } from "./merchants-manager";

/**
 * COUPONS Phase 1 — the merchant catalog and its reviewed aliases.
 *
 * This page is the ONLY way a merchant identity or an alias enters the system.
 * Both feed a matcher that decides, on someone's phone, that a line in their
 * bank statement is a particular business — so a careless alias here becomes a
 * wrong statement about a real person's spending, on every device, silently.
 * That is why aliases are unreviewed until an admin says otherwise, and why the
 * database refuses several things this form also refuses.
 */
export default async function MerchantsPage() {
  await requireAdmin();
  const supabase = await createAdminClient();

  const [{ data: merchants }, { data: aliases }] = await Promise.all([
    supabase
      .from("catalog_merchants")
      .select(
        "id, slug, name_ar, name_en, primary_domain, country_codes, is_active, is_deleted",
      )
      .order("slug", { ascending: true }),
    supabase
      .from("catalog_merchant_aliases")
      .select(
        "id, merchant_id, alias_raw, alias_normalized, alias_kind, country_code, priority, provenance, is_reviewed, is_active, is_deleted",
      )
      .eq("is_deleted", false)
      .order("created_at", { ascending: false }),
  ]);

  const merchantRows: MerchantRow[] = (merchants ?? []).map((m) => ({
    id: m.id as string,
    slug: m.slug as string,
    name_ar: m.name_ar as string,
    name_en: (m.name_en as string | null) ?? null,
    primary_domain: (m.primary_domain as string | null) ?? null,
    country_codes: (m.country_codes as string[] | null) ?? [],
    is_active: Boolean(m.is_active),
    is_deleted: Boolean(m.is_deleted),
  }));

  const aliasRows: AliasRow[] = (aliases ?? []).map((a) => ({
    id: a.id as string,
    merchant_id: a.merchant_id as string,
    alias_raw: a.alias_raw as string,
    alias_normalized: (a.alias_normalized as string | null) ?? "",
    alias_kind: a.alias_kind as string,
    country_code: (a.country_code as string | null) ?? null,
    priority: (a.priority as number | null) ?? 0,
    provenance: (a.provenance as string) ?? "admin",
    is_reviewed: Boolean(a.is_reviewed),
    is_active: Boolean(a.is_active),
  }));

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="كتالوج العروض"
        title="المتاجر والأسماء البديلة"
        description="هوية المتاجر المعتمدة، والأسماء التي تُطابَق بها أسماء المتاجر القادمة من رسائل البنوك."
      />

      <HelpNote>
        الاسم البديل المعتمد يُستخدم للمطابقة <strong>حرفيًا</strong>؛ لا يوجد
        تشابه تقريبي. إذا لم يطابق أي اسم بديل، لا يخمّن التطبيق — يتوقف. لذلك
        زيادة التغطية تكون بإضافة أسماء بديلة صحيحة، لا بتخفيف المطابقة. وأي اسم
        بديل جديد يبقى <strong>غير معتمد</strong> ولا يصل لأي جهاز حتى تعتمده.
      </HelpNote>

      <Link href="/merchants/shared-learning" className="text-tiny text-brand-700 underline">
        اقتراحات التعلّم المشترك للتصنيفات
      </Link>

      <MerchantsManager merchants={merchantRows} aliases={aliasRows} />
    </div>
  );
}
