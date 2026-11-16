"use client";

import { useState } from "react";
import { Users } from "lucide-react";
import { DataTable, TBody, TD, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";

export type CandidateRow = {
  merchant_key: string;
  category_key: string;
  user_count: number;
  merchant_user_count: number;
};

type Category = { key: string; name_ar: string };

export type PublishedRow = {
  merchant_key: string;
  category_key: string;
  published_category_key: string;
  auto_approved: boolean;
  user_count_at_review: number;
};

async function review(body: Record<string, unknown>, method: "POST" | "DELETE" = "POST") {
  const res = await fetch("/api/merchant-category-candidates", {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload?.error ?? `HTTP ${res.status}`);
  }
}

export function CandidatesManager({
  candidates,
  categories,
}: {
  candidates: CandidateRow[];
  categories: Category[];
}) {
  const [rows, setRows] = useState(candidates);
  const [choice, setChoice] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  const id = (r: CandidateRow) => `${r.merchant_key}|${r.category_key}`;

  async function decide(r: CandidateRow, decision: "approved" | "rejected") {
    setBusy(id(r));
    setMessage(null);
    try {
      const published = choice[id(r)] ?? r.category_key;
      await review({
        merchant_key: r.merchant_key,
        category_key: r.category_key,
        decision,
        published_category_key: decision === "approved" ? published : null,
      });
      setRows((all) => all.filter((x) => id(x) !== id(r)));
      setMessage(decision === "approved" ? "تم الاعتماد ونشره في الكتالوج." : "تم الرفض.");
    } catch (e) {
      setMessage(`فشلت العملية: ${(e as Error).message}`);
    } finally {
      setBusy(null);
    }
  }

  if (rows.length === 0) {
    return (
      <EmptyState
        icon={Users}
        title="لا توجد اقتراحات"
        description="لم يبلغ أي متجر حد المراجعة بعد."
      />
    );
  }

  return (
    <div className="space-y-3">
      {message && <p className="text-tiny text-ink-600">{message}</p>}
      <DataTable>
        <THead
          columns={["المتجر", "التصنيف المقترح", "مستخدمون متفقون", "التصنيف عند النشر", "القرار"]}
        />
        <TBody>
          {rows.map((r) => (
            <TR key={id(r)}>
              <TD className="font-mono">{r.merchant_key}</TD>
              <TD>{r.category_key}</TD>
              <TD>
                {r.user_count} / {r.merchant_user_count}
              </TD>
              <TD>
                <select
                  aria-label="التصنيف عند النشر"
                  value={choice[id(r)] ?? r.category_key}
                  onChange={(e) => setChoice((c) => ({ ...c, [id(r)]: e.target.value }))}
                  className="rounded-field border px-2 py-1 text-tiny"
                >
                  {categories.map((c) => (
                    <option key={c.key} value={c.key}>
                      {c.name_ar} ({c.key})
                    </option>
                  ))}
                </select>
              </TD>
              <TD>
                <div className="flex gap-2">
                  <button
                    type="button"
                    disabled={busy === id(r)}
                    onClick={() => decide(r, "approved")}
                    className="rounded-field bg-brand-600 px-3 py-1 text-tiny text-white disabled:opacity-50"
                  >
                    اعتماد
                  </button>
                  <button
                    type="button"
                    disabled={busy === id(r)}
                    onClick={() => decide(r, "rejected")}
                    className="rounded-field border px-3 py-1 text-tiny disabled:opacity-50"
                  >
                    رفض
                  </button>
                </div>
              </TD>
            </TR>
          ))}
        </TBody>
      </DataTable>
    </div>
  );
}

/** Published mappings (manual and auto). Revoke removes the mapping from
 * every device and the pair never auto-approves again. */
export function PublishedManager({ published }: { published: PublishedRow[] }) {
  const [rows, setRows] = useState(published);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const id = (r: PublishedRow) => `${r.merchant_key}|${r.category_key}`;

  async function revoke(r: PublishedRow) {
    setBusy(id(r));
    setMessage(null);
    try {
      await review({ merchant_key: r.merchant_key, category_key: r.category_key }, "DELETE");
      setRows((all) => all.filter((x) => id(x) !== id(r)));
      setMessage("تم الإلغاء وإزالته من الكتالوج.");
    } catch (e) {
      setMessage(`فشلت العملية: ${(e as Error).message}`);
    } finally {
      setBusy(null);
    }
  }

  if (rows.length === 0) return null;
  return (
    <div className="space-y-3">
      <h2 className="text-sm font-semibold">المنشور</h2>
      {message && <p className="text-tiny text-ink-600">{message}</p>}
      <DataTable>
        <THead columns={["المتجر", "التصنيف المنشور", "مستخدمون عند الاعتماد", "الاعتماد", "إجراء"]} />
        <TBody>
          {rows.map((r) => (
            <TR key={id(r)}>
              <TD className="font-mono">{r.merchant_key}</TD>
              <TD>{r.published_category_key}</TD>
              <TD>{r.user_count_at_review}</TD>
              <TD>
                {r.auto_approved ? (
                  <StatusBadge label="معتمد تلقائيًا" tone="info" />
                ) : (
                  <StatusBadge label="اعتماد يدوي" />
                )}
              </TD>
              <TD>
                <button
                  type="button"
                  disabled={busy === id(r)}
                  onClick={() => revoke(r)}
                  className="rounded-field border px-3 py-1 text-tiny disabled:opacity-50"
                >
                  إلغاء
                </button>
              </TD>
            </TR>
          ))}
        </TBody>
      </DataTable>
    </div>
  );
}
