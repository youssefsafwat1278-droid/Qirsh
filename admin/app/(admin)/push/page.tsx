"use client";

import { useEffect, useState } from "react";
import { FlaskConical, RefreshCw, Send, Users } from "lucide-react";
import {
  Banner,
  Card,
  EmptyState,
  ErrorState,
  HelpNote,
  LoadingState,
  PageHeader,
  SectionHeader,
  StatCard,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, SelectField, TextAreaField, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import {
  BODY_MAX,
  BROADCAST_DEEP_LINKS,
  TITLE_MAX,
  broadcastErrorMessage,
  parseTestTarget,
  validateBroadcastDraft,
} from "@/lib/push-broadcast.mjs";
import { fmtDate, fmtDateTime } from "@/lib/utils";

type Draft = { title_ar: string; title_en: string; body_ar: string; body_en: string; deep_link: string };
type DryRun = { devices: number; users: number };
type HistoryRow = {
  id: string;
  created_at: string;
  title_ar: string;
  deep_link: string | null;
  recipient_devices: number;
  recipient_users: number;
  is_test?: boolean;
  pending: number;
  sent: number;
  failed: number;
  skipped: number;
  retryable: number;
  top_error: string | null;
  /** When the scheduled retry (every 10 min, 72 h window) next looks at it; null = none pending. */
  next_auto_retry_at?: string | null;
};

const emptyDraft: Draft = { title_ar: "", title_en: "", body_ar: "", body_en: "", deep_link: "" };
const LINK_OPTIONS = [{ value: "", label: "بدون وجهة — يفتح التطبيق فقط" }, ...BROADCAST_DEEP_LINKS];

export default function PushBroadcastsPage() {
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [dryRun, setDryRun] = useState<DryRun | null>(null);
  const [history, setHistory] = useState<HistoryRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [confirm, setConfirm] = useState<ConfirmSpec | null>(null);
  const [testTarget, setTestTarget] = useState("");
  // One id per composed message: a double submit or a retried request replays
  // the same create instead of making a second broadcast.
  const [operationId, setOperationId] = useState(() => crypto.randomUUID());

  async function loadHistory() {
    const res = await fetch("/api/push-broadcasts");
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(json.error ?? "history_unavailable");
    setHistory((json.broadcasts ?? []) as HistoryRow[]);
  }

  useEffect(() => {
    loadHistory()
      .catch(() => setLoadError("تعذّر تحميل سجل الإرسال"))
      .finally(() => setLoading(false));
  }, []);

  function set<K extends keyof Draft>(field: K, value: Draft[K]) {
    setDraft((prev) => ({ ...prev, [field]: value }));
    // Any edit invalidates the preview: the count must be re-confirmed.
    setDryRun(null);
  }

  async function runDryRun() {
    const check = validateBroadcastDraft(draft);
    if (!check.ok) return setError(broadcastErrorMessage("validation_failed"));
    setBusy(true);
    setError("");
    const res = await fetch("/api/push-broadcasts/dry-run", { method: "POST" });
    const json = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) return setError(broadcastErrorMessage(json.error));
    setDryRun(json as DryRun);
  }

  function requestSend() {
    if (!dryRun) return;
    if (dryRun.devices === 0) return setError(broadcastErrorMessage("no_recipients"));
    setConfirm({
      title: "إرسال إشعار لكل المستلمين",
      consequence: (
        <>
          <p>
            سيصل الإشعار إلى <b>{dryRun.devices}</b> جهاز لدى <b>{dryRun.users}</b> مستخدم، ويُحفظ أيضًا كإعلان
            داخل التطبيق لمدة 14 يومًا. لا يمكن سحب إشعار بعد وصوله.
          </p>
          <p className="mt-2">«{draft.title_ar}»</p>
        </>
      ),
      confirmLabel: "إرسال الآن",
      tone: "warning",
      typeToConfirm: String(dryRun.devices),
      typeToConfirmLabel: `اكتب عدد الأجهزة (${dryRun.devices}) للتأكيد`,
    });
  }

  async function send() {
    if (!dryRun) return;
    setConfirm(null);
    setBusy(true);
    setError("");
    setNotice("");
    const res = await fetch("/api/push-broadcasts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...draft, operation_id: operationId, typed_confirmation: String(dryRun.devices) }),
    });
    const json = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) {
      if (json.error === "recipient_count_changed") setDryRun(null);
      return setError(broadcastErrorMessage(json.error));
    }
    if (json.error) setError(broadcastErrorMessage(json.error));
    else setNotice("تم إنشاء الرسالة وبدأ الإرسال.");
    setDraft(emptyDraft);
    setDryRun(null);
    setOperationId(crypto.randomUUID());
    await loadHistory().catch(() => undefined);
  }

  // A test goes to one account's devices only, with no in-app announcement.
  // Its own operation id each time: every click is a new test.
  async function sendTest() {
    const check = validateBroadcastDraft(draft);
    if (!check.ok) return setError(broadcastErrorMessage("validation_failed"));
    if (!parseTestTarget(testTarget)) return setError(broadcastErrorMessage("test_target_invalid"));
    setBusy(true);
    setError("");
    setNotice("");
    const res = await fetch("/api/push-broadcasts/test", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...draft, target: testTarget, operation_id: crypto.randomUUID() }),
    });
    const json = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) return setError(broadcastErrorMessage(json.error));
    if (json.error) setError(broadcastErrorMessage(json.error));
    else {
      const s = json.send as { sent?: number; failed?: number } | null;
      setNotice(`أُرسلت التجربة إلى ${json.created?.devices ?? 0} جهاز — وصل ${s?.sent ?? 0}، فشل ${s?.failed ?? 0}.`);
    }
    await loadHistory().catch(() => undefined);
  }

  async function retry(id: string) {
    setBusy(true);
    setError("");
    const res = await fetch("/api/push-broadcasts/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ broadcast_id: id }),
    });
    const json = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) setError(broadcastErrorMessage(json.error));
    else setNotice("أُعيدت محاولة الأجهزة التي لم يصلها الإشعار.");
    await loadHistory().catch(() => undefined);
  }

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="النمو والمكافآت"
        title="إشعارات من قرش"
        description="رسالة خدمة تصل كإشعار إلى أجهزة مستخدمي السحابة، وتُحفظ كإعلان داخل التطبيق لمن فاته الإشعار."
      />

      <HelpNote>
        يصل الإشعار فقط لمن فعّل السحابة على حسابه وعلى جهازه، ولم يُوقف «رسائل من قرش» في إعدادات التنبيهات.
        تُختار اللغة حسب لغة التطبيق لدى المستخدم (العربية افتراضيًا). رسائل خدمة فقط — لا عروض تسويقية.
      </HelpNote>

      {error && <Banner tone="danger" onDismiss={() => setError("")}>{error}</Banner>}
      {notice && <Banner tone="success" onDismiss={() => setNotice("")}>{notice}</Banner>}

      <Card>
        <SectionHeader title="رسالة جديدة" description="اكتب الرسالة باللغتين، ثم عاين عدد المستلمين قبل الإرسال." />
        <div className="space-y-5">
          <div className="grid gap-4 md:grid-cols-2">
            <TextField
              label="العنوان بالعربية"
              required
              maxLength={TITLE_MAX}
              value={draft.title_ar}
              onChange={(e) => set("title_ar", e.target.value)}
            />
            <TextField
              label="العنوان بالإنجليزية"
              required
              dir="ltr"
              maxLength={TITLE_MAX}
              value={draft.title_en}
              onChange={(e) => set("title_en", e.target.value)}
            />
            <TextAreaField
              label="النص بالعربية"
              required
              rows={3}
              maxLength={BODY_MAX}
              value={draft.body_ar}
              onChange={(e) => set("body_ar", e.target.value)}
            />
            <TextAreaField
              label="النص بالإنجليزية"
              required
              dir="ltr"
              rows={3}
              maxLength={BODY_MAX}
              value={draft.body_en}
              onChange={(e) => set("body_en", e.target.value)}
            />
          </div>
          <SelectField
            label="الوجهة عند الضغط"
            value={draft.deep_link}
            onChange={(e) => set("deep_link", e.target.value)}
            options={LINK_OPTIONS}
            hint="صفحات داخل التطبيق فقط. بدون وجهة يفتح التطبيق وتظهر الرسالة كإعلان."
          />

          <div className="flex flex-col gap-2.5 rounded-lg border border-divider p-4 md:flex-row md:items-end">
            <div className="flex-1">
              <TextField
                label="تجربة على حساب واحد"
                dir="ltr"
                placeholder="email@example.com أو User ID"
                value={testTarget}
                onChange={(e) => setTestTarget(e.target.value)}
                hint="يصل الإشعار لأجهزة هذا الحساب فقط، ولا يُنشأ إعلان داخل التطبيق."
              />
            </div>
            <Button variant="secondary" icon={FlaskConical} onClick={() => void sendTest()} disabled={busy}>
              إرسال تجربة
            </Button>
          </div>

          {dryRun && (
            <div className="grid gap-4 md:grid-cols-2">
              <StatCard icon={Send} label="جهاز سيصله الإشعار" value={dryRun.devices} />
              <StatCard icon={Users} label="مستخدم" value={dryRun.users} />
            </div>
          )}

          <div className="flex justify-end gap-2.5 border-t border-divider pt-4">
            <Button variant="secondary" icon={Users} onClick={runDryRun} loading={busy && !dryRun}>
              معاينة المستلمين
            </Button>
            <Button icon={Send} onClick={requestSend} disabled={!dryRun || busy} loading={busy && Boolean(dryRun)}>
              إرسال
            </Button>
          </div>
        </div>
      </Card>

      <SectionHeader title="سجل الإرسال" />
      {loading ? (
        <LoadingState label="جارٍ تحميل السجل…" />
      ) : loadError ? (
        <ErrorState title="تعذّر تحميل السجل" detail={loadError} />
      ) : history.length === 0 ? (
        <Card padded={false}>
          <EmptyState icon={Send} title="لم تُرسل أي رسالة بعد" description="الرسائل المرسلة تظهر هنا مع حالة كل جهاز." />
        </Card>
      ) : (
        <div className="space-y-3">
          {history.map((b) => (
            <Card key={b.id}>
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0 flex-1">
                  <p className="font-medium text-ink">
                    {b.title_ar}
                    {b.is_test && <span className="ms-2"><StatusBadge label="تجربة" tone="warning" dot={false} /></span>}
                  </p>
                  <p className="mt-1 text-micro text-ink-faint">
                    {fmtDate(b.created_at)} — {b.recipient_devices} جهاز / {b.recipient_users} مستخدم
                    {b.deep_link ? ` — ${b.deep_link}` : ""}
                  </p>
                  <div className="mt-2 flex flex-wrap gap-2">
                    <StatusBadge label={`بانتظار الإرسال ${b.pending}`} tone="info" />
                    <StatusBadge label={`أُرسل ${b.sent}`} tone="success" />
                    <StatusBadge label={`فشل ${b.failed}`} tone={b.failed ? "danger" : "neutral"} />
                    <StatusBadge label={`تم تخطيه ${b.skipped}`} tone="neutral" />
                    {b.top_error && <StatusBadge label={b.top_error} tone="warning" dot={false} />}
                    {b.retryable > 0 && b.next_auto_retry_at && (
                      <StatusBadge
                        label={`إعادة تلقائية بعد ${fmtDateTime(b.next_auto_retry_at)}`}
                        tone="info"
                        dot={false}
                      />
                    )}
                  </div>
                </div>
                {b.retryable > 0 && (
                  <Button size="sm" variant="secondary" icon={RefreshCw} disabled={busy} onClick={() => retry(b.id)}>
                    إعادة المحاولة ({b.retryable})
                  </Button>
                )}
              </div>
            </Card>
          ))}
        </div>
      )}

      <ConfirmDialog spec={confirm} busy={busy} onCancel={() => setConfirm(null)} onConfirm={() => void send()} />
    </div>
  );
}
