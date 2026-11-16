import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { HelpNote, PageHeader } from "@/components/ui/primitives";
import { CandidatesManager, type CandidateRow } from "./candidates-manager";

/**
 * Shared category learning — candidates from users' "Remember for this
 * merchant" choices. A row appears once at least 5 DIFFERENT users chose the
 * same category for the same merchant. 5 is a starting threshold for review,
 * not a privacy guarantee: nothing reaches any device until an admin approves.
 */
export default async function SharedLearningPage() {
  const admin = await requireAdmin();
  const supabase = await createAdminClient();

  const [{ data: candidates, error }, { data: categories }] = await Promise.all([
    supabase.rpc("admin_list_merchant_category_candidates", { p_actor: admin.id }),
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
        للمتجر نفسه. هذا الحد بداية للمراجعة فقط، وليس ضمانًا للخصوصية ولا نشرًا تلقائيًا: لا
        يصل أي اقتراح إلى الأجهزة إلا بعد اعتمادك. المرفوض لا يعود للظهور.
      </HelpNote>
      {error ? (
        <HelpNote tone="warning">تعذّر تحميل الاقتراحات.</HelpNote>
      ) : (
        <CandidatesManager candidates={rows} categories={categoryOptions} />
      )}
    </div>
  );
}
