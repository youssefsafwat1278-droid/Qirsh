"use client";

import { useEffect, useState } from "react";
import { Bell, Pencil, Plus, Save, Trash2 } from "lucide-react";
import {
  Banner,
  Card,
  EmptyState,
  ErrorState,
  HelpNote,
  LoadingState,
  PageHeader,
  SectionHeader,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, CheckboxField, SelectField, TextAreaField, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import {
  FORCE_UPDATE_CONFIRM_PHRASE,
  armsForceUpdate,
} from "@/lib/announcement-guard.mjs";
import { SEVERITY_OPTIONS, severityLabel, severityTone } from "@/lib/labels";
import { fmtDate } from "@/lib/utils";

type Announcement = {
  id?: string;
  title_ar: string;
  title_en: string;
  body_ar: string;
  body_en: string;
  severity: string;
  action_label_ar: string;
  action_label_en: string;
  action_url: string;
  valid_from: string;
  valid_until: string;
  min_app_version: string;
  max_app_version: string;
  is_dismissible: boolean;
  priority: number;
  is_active: boolean;
};

const empty: Announcement = {
  title_ar: "",
  title_en: "",
  body_ar: "",
  body_en: "",
  severity: "info",
  action_label_ar: "",
  action_label_en: "",
  action_url: "",
  valid_from: new Date().toISOString().slice(0, 16),
  valid_until: "",
  min_app_version: "",
  max_app_version: "",
  is_dismissible: true,
  priority: 0,
  is_active: true,
};

// Types whose audience is narrowed by app version. update_available needs
// max_app_version so users who already updated stop seeing it.
const VERSION_TARGETED = ["force_update", "update_available", "release_notes"];

export default function AnnouncementsPage() {
  const [announcements, setAnnouncements] = useState<Announcement[]>([]);
  const [form, setForm] = useState<Announcement | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [confirm, setConfirm] = useState<(ConfirmSpec & { id: string }) | null>(null);

  useEffect(() => {
    fetch("/api/announcements")
      .then(async (res) => {
        const json = await res.json();
        if (!res.ok) throw new Error(json.error ?? "تعذّر تحميل الإعلانات");
        setAnnouncements((json.announcements ?? []) as Announcement[]);
      })
      .catch((err) => setLoadError(err instanceof Error ? err.message : "تعذّر تحميل الإعلانات"))
      .finally(() => setLoading(false));
  }, []);

  function set<K extends keyof Announcement>(field: K, value: Announcement[K]) {
    setForm((prev) => (prev ? { ...prev, [field]: value } : prev));
  }

  // F-017 — arming a force-update goes through a typed, consequence-first
  // confirmation. Ordinary announcements keep the single-click save.
  const [armConfirm, setArmConfirm] = useState<ConfirmSpec | null>(null);

  function requestSave() {
    if (!form) return;
    if (!form.title_ar.trim()) return setError("عنوان الإعلان بالعربية مطلوب.");
    if (form.severity === "update_available" && !form.action_url.trim()) {
      return setError("رابط المتجر مطلوب لإعلان «تحديث متاح» — هو وجهة زر التحديث.");
    }
    if (armsForceUpdate(form)) {
      const range =
        form.min_app_version || form.max_app_version
          ? `النطاق المستهدف: ${form.min_app_version || "بدون حد أدنى"} ← ${
              form.max_app_version || "بدون حد أقصى"
            }`
          : "بدون قيود إصدار — سيُحجب كل مستخدم مثبَّت لديه التطبيق حتى يحدّثه";
      setArmConfirm({
        title: "نشر تحديث إجباري",
        consequence: (
          <>
            <p>
              هذا الإجراء <b>يمنع المستخدمين من متابعة استخدام التطبيق</b> حتى
              يقوموا بالتحديث.
            </p>
            <p dir="ltr" style={{ textAlign: "right" }}>{range}</p>
          </>
        ),
        confirmLabel: "نشر الحجب الإجباري",
        tone: "danger",
        typeToConfirm: FORCE_UPDATE_CONFIRM_PHRASE,
        typeToConfirmLabel: `اكتب «${FORCE_UPDATE_CONFIRM_PHRASE}» للتأكيد`,
      });
      return;
    }
    void save(false);
  }

  async function save(confirmForceUpdate: boolean) {
    if (!form) return;
    if (!form.title_ar.trim()) return setError("عنوان الإعلان بالعربية مطلوب.");
    setSaving(true);
    setError("");
    setNotice("");
    const payload = {
      ...form,
      valid_until: form.valid_until || null,
      // F-017 — the API refuses to arm a force-update without this token.
      confirm_force_update: confirmForceUpdate,
    };
    const res = await fetch("/api/announcements", {
      method: form.id ? "PATCH" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const json = await res.json();
    setSaving(false);
    if (!res.ok) {
      setError(json.error ?? "تعذّر حفظ الإعلان");
      return;
    }
    const savedRow = json.announcement as Announcement;
    setAnnouncements((prev) =>
      form.id ? prev.map((a) => (a.id === form.id ? savedRow : a)) : [savedRow, ...prev],
    );
    setNotice(form.id ? "تم تحديث الإعلان." : "تم نشر الإعلان.");
    setForm(null);
  }

  async function remove() {
    if (!confirm) return;
    setDeleting(true);
    setError("");
    const res = await fetch(`/api/announcements?id=${encodeURIComponent(confirm.id)}`, {
      method: "DELETE",
    });
    setDeleting(false);
    const id = confirm.id;
    setConfirm(null);
    if (!res.ok) {
      const json = await res.json().catch(() => ({}));
      setError(json.error ?? "تعذّر حذف الإعلان");
      return;
    }
    setAnnouncements((prev) => prev.filter((a) => a.id !== id));
    setNotice("تم حذف الإعلان.");
  }

  const liveCount = announcements.filter((a) => a.is_active).length;

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="النمو والمكافآت"
        title="الإعلانات داخل التطبيق"
        description={`${liveCount} إعلان معروض حاليًا. تظهر هذه الرسائل كلافتة داخل التطبيق لجميع المستخدمين خلال الفترة التي تحدّدها.`}
        action={
          !form && (
            <Button icon={Plus} onClick={() => setForm(empty)}>
              إعلان جديد
            </Button>
          )
        }
      />

      <HelpNote tone="warning">
        نوع «تحديث إجباري» يمنع المستخدم من متابعة استخدام التطبيق حتى يحدّثه. لا تستخدمه إلا عند
        وجود سبب فعلي يمنع تشغيل النسخة القديمة.
      </HelpNote>

      <HelpNote>
        «تحديث متاح» لافتة يستطيع المستخدم إغلاقها ولا تمنعه من الاستخدام؛ حدّد أعلى إصدار مستهدف
        لتظهر فقط لمن لديه نسخة أقدم. «ما الجديد» يظهر في صفحة «ما الجديد» داخل الإعدادات فوق
        الملاحظات المضمّنة في التطبيق.
      </HelpNote>

      {error && <Banner tone="danger" onDismiss={() => setError("")}>{error}</Banner>}
      {notice && <Banner tone="success" onDismiss={() => setNotice("")}>{notice}</Banner>}

      {form && (
        <Card>
          <SectionHeader
            title={form.id ? "تعديل الإعلان" : "إعلان جديد"}
            description="اكتب الرسالة كما ستظهر للمستخدم، وحدّد الفترة التي تظهر خلالها."
          />

          <div className="space-y-5">
            <div className="grid gap-4 md:grid-cols-2">
              <TextField
                label="العنوان بالعربية"
                required
                value={form.title_ar}
                onChange={(e) => set("title_ar", e.target.value)}
                hint="أول سطر يقرأه المستخدم — اجعله قصيرًا وواضحًا."
              />
              <TextField
                label="العنوان بالإنجليزية"
                dir="ltr"
                value={form.title_en}
                onChange={(e) => set("title_en", e.target.value)}
              />
              <TextAreaField
                label="النص بالعربية"
                rows={3}
                value={form.body_ar}
                onChange={(e) => set("body_ar", e.target.value)}
              />
              <TextAreaField
                label="النص بالإنجليزية"
                dir="ltr"
                rows={3}
                value={form.body_en}
                onChange={(e) => set("body_en", e.target.value)}
              />
            </div>

            <div className="grid gap-4 md:grid-cols-3">
              <SelectField
                label="نوع الإعلان"
                value={form.severity}
                onChange={(e) => set("severity", e.target.value)}
                options={SEVERITY_OPTIONS}
                hint="النوع يحدّد شكل اللافتة ومدى إلحاحها."
              />
              <TextField
                label="يبدأ الظهور في"
                type="datetime-local"
                value={form.valid_from}
                onChange={(e) => set("valid_from", e.target.value)}
              />
              <TextField
                label="يتوقف الظهور في"
                type="datetime-local"
                value={form.valid_until}
                onChange={(e) => set("valid_until", e.target.value)}
                hint="اتركه فارغًا ليبقى الإعلان ظاهرًا بلا تاريخ انتهاء."
              />
            </div>

            {VERSION_TARGETED.includes(form.severity) && (
              <div className="grid gap-4 md:grid-cols-2">
                <TextField
                  label="أقل إصدار مستهدف (min_app_version)"
                  dir="ltr"
                  mono
                  value={form.min_app_version}
                  onChange={(e) => set("min_app_version", e.target.value)}
                  hint={
                    form.severity === "force_update"
                      ? "مثال: 1.2.0 — يُحجب من إصداره ≥ هذا الحد."
                      : "مثال: 1.2.0 — يظهر لمن إصداره ≥ هذا الحد."
                  }
                />
                <TextField
                  label="أعلى إصدار مستهدف (max_app_version)"
                  dir="ltr"
                  mono
                  value={form.max_app_version}
                  onChange={(e) => set("max_app_version", e.target.value)}
                  hint={
                    form.severity === "force_update"
                      ? "مثال: 1.4.9 — يُحجب من إصداره ≤ هذا الحد. الفراغ في الحقلين = حجب الجميع."
                      : form.severity === "update_available"
                        ? "اكتب آخر إصدار قديم (مثال: 1.0.0) — تظهر اللافتة فقط لمن إصداره ≤ هذا الحد، فلا يراها من حدّث."
                        : "مثال: 1.4.9 — يظهر لمن إصداره ≤ هذا الحد. الفراغ = كل الإصدارات."
                  }
                />
              </div>
            )}

            <div className="grid gap-4 md:grid-cols-3">
              <TextField
                label="نص زر الإجراء بالعربية"
                value={form.action_label_ar}
                onChange={(e) => set("action_label_ar", e.target.value)}
                hint="اتركه فارغًا إذا كان الإعلان للقراءة فقط."
              />
              <TextField
                label="نص زر الإجراء بالإنجليزية"
                dir="ltr"
                value={form.action_label_en}
                onChange={(e) => set("action_label_en", e.target.value)}
              />
              <TextField
                label="رابط الزر"
                mono
                value={form.action_url}
                onChange={(e) => set("action_url", e.target.value)}
                hint="الوجهة التي يفتحها الزر عند الضغط عليه."
              />
            </div>

            <div className="flex flex-wrap items-start gap-8">
              <CheckboxField
                label="يمكن للمستخدم إخفاء الإعلان"
                hint="عند الإلغاء يبقى الإعلان ظاهرًا ولا يستطيع المستخدم إغلاقه."
                checked={form.is_dismissible}
                onChange={(v) => set("is_dismissible", v)}
              />
              <CheckboxField
                label="الإعلان مفعّل"
                hint="أوقفه لإخفائه فورًا مع الاحتفاظ بمحتواه."
                checked={form.is_active}
                onChange={(v) => set("is_active", v)}
              />
            </div>

            <div className="flex justify-end gap-2.5 border-t border-divider pt-4">
              <Button variant="secondary" onClick={() => setForm(null)}>
                إلغاء
              </Button>
              <Button icon={Save} onClick={requestSave} loading={saving}>
                {form.id ? "حفظ التعديلات" : "نشر الإعلان"}
              </Button>
            </div>
          </div>
        </Card>
      )}

      {loading ? (
        <LoadingState label="جارٍ تحميل الإعلانات…" />
      ) : loadError ? (
        <ErrorState title="تعذّر تحميل الإعلانات" detail={loadError} />
      ) : announcements.length === 0 ? (
        <Card padded={false}>
          <EmptyState
            icon={Bell}
            title="لا توجد إعلانات بعد"
            description="أنشئ إعلانًا عندما تحتاج إلى إبلاغ كل المستخدمين بشيء داخل التطبيق."
            action={
              !form && (
                <Button icon={Plus} onClick={() => setForm(empty)}>
                  إعلان جديد
                </Button>
              )
            }
          />
        </Card>
      ) : (
        <div className="space-y-3">
          {announcements.map((a) => (
            <Card key={a.id} className={a.is_active ? undefined : "opacity-70"}>
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0 flex-1">
                  <div className="mb-2 flex flex-wrap items-center gap-2">
                    <StatusBadge label={severityLabel(a.severity)} tone={severityTone(a.severity)} />
                    <StatusBadge
                      label={a.is_active ? "معروض" : "متوقف"}
                      tone={a.is_active ? "success" : "neutral"}
                    />
                    {!a.is_dismissible && (
                      <StatusBadge label="لا يمكن إخفاؤه" tone="warning" dot={false} />
                    )}
                  </div>
                  <p className="font-medium text-ink">{a.title_ar}</p>
                  {a.body_ar && <p className="mt-1 text-sm text-ink-soft">{a.body_ar}</p>}
                  <p className="mt-2 text-micro text-ink-faint">
                    يظهر من {fmtDate(a.valid_from)}{" "}
                    {a.valid_until ? `حتى ${fmtDate(a.valid_until)}` : "— بلا تاريخ انتهاء"}
                  </p>
                </div>

                <div className="flex shrink-0 gap-2">
                  <Button size="sm" variant="secondary" icon={Pencil} onClick={() => setForm(a)}>
                    تعديل
                  </Button>
                  <Button
                    size="sm"
                    variant="danger"
                    icon={Trash2}
                    onClick={() =>
                      setConfirm({
                        id: a.id!,
                        title: "حذف هذا الإعلان نهائيًا؟",
                        consequence: (
                          <>
                            سيختفي «{a.title_ar}» من التطبيق ولن يمكن استرجاع نصّه.
                            <br />
                            <strong className="text-ink">
                              إذا أردت إخفاءه فقط، عدّله وألغِ تفعيله — يبقى المحتوى محفوظًا.
                            </strong>
                          </>
                        ),
                        confirmLabel: "حذف نهائيًا",
                        tone: "danger",
                      })
                    }
                  >
                    حذف
                  </Button>
                </div>
              </div>
            </Card>
          ))}
        </div>
      )}

      <ConfirmDialog
        spec={confirm}
        busy={deleting}
        onCancel={() => setConfirm(null)}
        onConfirm={remove}
      />
      {/* F-017 — typed confirmation for ARMING a force-update. Cancel = zero
          mutation: no request is issued until onConfirm fires. */}
      <ConfirmDialog
        spec={armConfirm}
        busy={saving}
        onCancel={() => setArmConfirm(null)}
        onConfirm={() => {
          setArmConfirm(null);
          void save(true);
        }}
      />
    </div>
  );
}
