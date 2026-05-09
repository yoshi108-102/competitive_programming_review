"use client";

import Link from "next/link";
import { use, useEffect, useState } from "react";
import { ApiCallError, api } from "@/app/lib/api";
import type { Submission } from "@/app/lib/types";

type PageProps = {
  params: Promise<{ submission_id: string }>;
};

export default function SubmissionDetail({ params }: PageProps) {
  // Next.js 16: params は Promise なので React の use() で unwrap
  // → docs/learning/phase1/task12/01-nextjs-client-page-with-auth-and-api.md §F
  const { submission_id } = use(params);

  const [item, setItem] = useState<Submission | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      try {
        const data = await api.getSubmission(submission_id);
        if (!cancelled) setItem(data);
      } catch (err) {
        if (cancelled) return;
        if (err instanceof ApiCallError && err.status === 404) {
          setNotFound(true);
        } else {
          setError(
            err instanceof ApiCallError ? err.message : "取得に失敗しました",
          );
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [submission_id]);

  if (loading) return <p className="text-zinc-500">読み込み中...</p>;
  if (notFound) {
    return (
      <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
        <p className="text-zinc-700 dark:text-zinc-300">
          指定の提出が見つかりません。
        </p>
        <Link
          href="/submissions"
          className="mt-4 inline-block text-blue-600 hover:underline dark:text-blue-400"
        >
          ← 提出一覧へ戻る
        </Link>
      </div>
    );
  }
  if (error) {
    return <p className="text-red-600 dark:text-red-400">{error}</p>;
  }
  if (!item) return null;

  return (
    <div className="space-y-6">
      <Link
        href="/submissions"
        className="text-sm text-blue-600 hover:underline dark:text-blue-400"
      >
        ← 提出一覧へ戻る
      </Link>

      <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="font-mono text-xl font-semibold text-zinc-900 dark:text-zinc-50">
          {item.problem_id}
        </h2>
        <p className="mt-1 text-sm text-zinc-500">
          {new Date(item.epoch_second * 1000).toLocaleString("ja-JP")}
        </p>

        <dl className="mt-6 grid grid-cols-2 gap-4 text-sm">
          <Field label="結果" value={item.result} />
          <Field label="得点" value={item.point} />
          <Field label="言語" value={item.language} />
          <Field label="コード長" value={`${item.length} bytes`} />
          <Field
            label="実行時間"
            value={item.execution_time != null ? `${item.execution_time} ms` : "-"}
          />
          <Field label="コンテスト" value={item.contest_id} />
        </dl>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-xs uppercase text-zinc-500 dark:text-zinc-400">
        {label}
      </dt>
      <dd className="mt-1 font-medium text-zinc-900 dark:text-zinc-50">
        {value}
      </dd>
    </div>
  );
}
