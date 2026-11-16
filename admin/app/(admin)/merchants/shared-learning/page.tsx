import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { HelpNote, PageHeader } from "@/components/ui/primitives";
import {
  CandidatesManager,
  PublishedManager,
  type CandidateRow,
  type PublishedRow,
} from "./candidates-manager";

/**
 * Shared category learning — candidates from users' "Remember for this
 * merchant" choices. A row appears once at least 5 DIFFERENT users chose the
 * same category for the same merchant. 5 is a starting threshold for review,
 * not a privacy guarantee. A pair with 6+ users that also holds at least 75%
 * of the merchant's users is published automatically (owner rule) and listed
 * below as auto-approved, where the admin can revoke it.
 */
export default async function SharedLearningPage() {
  const admin = await requireAdmin();
  const supabase = await createAdminClient();

  const [{ data: candidates, error }, { data: published }, { data: categories }] = await Promise.all([
    supabase.rpc("admin_list_merchant_category_candidates", { p_actor: admin.id }),
    supabase.rpc("admin_list_merchant_category_published", { p_actor: admin.id }),
    supabase
      .from("categories")
      .select("key, name_ar")
      .eq("is_active", true)
      .eq("is_deleted", false)
      .order("sort_order", { ascending: true }),
  ]);

  const rows: CandidateRow[] = ((candidates as CandidateRow[] | null) ?? []).map((c) => ({
    merchant_key: c.merchant_key,
    category_key: c.category_key,
    user_count: Number(c.user_count),
    merchant_user_count: Number(c.merchant_user_count),
  }));
  const publishedRows: PublishedRow[] = ((published as PublishedRow[] | null) ?? []).map((p) => ({
    merchant_key: p.merchant_key,
    category_key: p.category_key,
    published_category_key: p.published_category_key,
    auto_approved: Boolean(p.auto_approved),
    user_count_at_review: Number(p.user_count_at_review),
  }));
  const categoryOptions = ((categories ?? []) as { key: string; name_ar: string }[]).filter(
    (c) => !["transfers", "income", "cash", "other", "all_expenses"].includes(c.key),
  );

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="كتالوج المتاجر"
        title="التعلّم المشترك للتصنيفات"
        description="اقتراحات من اختيار المستخدمين «تذكّر التصنيف لهذا المتجر» بعد موافقتهم على المزامنة السحابية والتحليل الذكي."
      />
      <HelpNote>
        يظهر الاقتراح عندما يختار <strong>5 مستخدمين مختلفين على الأقل</strong> التصنيف نفسه
        للمتجر نفسه. هذا الحد بداية للمراجعة فقط، وليس ضمانًا للخصوصية. وإذا اختاره{" "}
        <strong>6 مستخدمين أو أكثر</strong> وكانوا <strong>75% على الأقل</strong> ممن صنّفوا هذا
        المتجر، يُنشر تلقائيًا ويظهر أدناه بشارة «معتمد تلقائيًا»، ويمكنك إلغاؤه. المرفوض أو الملغى
        لا يعود للظهور ولا يُعتمد تلقائيًا.
      </HelpNote>
      {error ? (
        <HelpNote tone="warning">تعذّر تحميل الاقتراحات.</HelpNote>
      ) : (
        <CandidatesManager candidates={rows} categories={categoryOptions} />
      )}
      <PublishedManager published={publishedRows} />
    </div>
  );
}
