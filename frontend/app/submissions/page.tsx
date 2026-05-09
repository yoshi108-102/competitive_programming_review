"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { ApiCallError, api } from "@/app/lib/api";
import type { Submission } from "@/app/lib/types";

export default function SubmissionsPage() {
  const [items, setItems] = useState<Submission[]>([]);
  const [nextToken, setNextToken] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [syncMessage, setSyncMessage] = useState<string | null>(null);

  const loadInitial = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const { items, nextToken } = await api.listSubmissions({ limit: 20 });
      setItems(items);
      setNextToken(nextToken);
    } catch (err) {
      setError(
        err instanceof ApiCallError ? err.message : "取得に失敗しました",
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { items, nextToken } = await api.listSubmissions({ limit: 20 });
        if (!cancelled) {
          setItems(items);
          setNextToken(nextToken);
        }
      } catch (err) {
        if (!cancelled) {
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
  }, []);

  async function loadMore() {
    if (!nextToken || loadingMore) return;
    setLoadingMore(true);
    try {
      const { items: more, nextToken: token } = await api.listSubmissions({
        limit: 20,
        nextToken,
      });
      setItems((prev) => [...prev, ...more]);
      setNextToken(token);
    } catch (err) {
      setError(
        err instanceof ApiCallError ? err.message : "追加取得に失敗しました",
      );
    } finally {
      setLoadingMore(false);
    }
  }

  async function onSync() {
    setSyncing(true);
    setSyncMessage(null);
    setError(null);
    try {
      const result = await api.syncSubmissions();
      setSyncMessage(`${result.synced_count} 件取得しました`);
      // 同期後は一覧を再ロード
      await loadInitial();
    } catch (err) {
      setError(
        err instanceof ApiCallError ? err.message : "同期に失敗しました",
      );
    } finally {
      setSyncing(false);
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
          提出一覧
        </h2>
        <button
          onClick={onSync}
          disabled={syncing}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {syncing ? "同期中..." : "AtCoder と同期"}
        </button>
      </div>

      {syncMessage && (
        <p className="text-sm text-green-600 dark:text-green-400">
          {syncMessage}
        </p>
      )}
      {error && (
        <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
      )}

      {loading ? (
        <p className="text-zinc-500">読み込み中...</p>
      ) : items.length === 0 ? (
        <p className="text-zinc-500">
          提出がありません。「AtCoder と同期」ボタンで取得してください。
        </p>
      ) : (
        <>
          <SubmissionsTable items={items} />
          {nextToken && (
            <button
              onClick={loadMore}
              disabled={loadingMore}
              className="mx-auto block rounded-md border border-zinc-300 bg-white px-4 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              {loadingMore ? "読み込み中..." : "もっと見る"}
            </button>
          )}
        </>
      )}
    </div>
  );
}

function SubmissionsTable({ items }: { items: Submission[] }) {
  return (
    <div className="overflow-hidden rounded-lg border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <table className="w-full text-sm">
        <thead className="border-b border-zinc-200 bg-zinc-50 text-left text-xs uppercase text-zinc-500 dark:border-zinc-800 dark:bg-zinc-800 dark:text-zinc-400">
          <tr>
            <th className="px-4 py-3">提出時刻</th>
            <th className="px-4 py-3">問題</th>
            <th className="px-4 py-3">結果</th>
            <th className="px-4 py-3">言語</th>
            <th className="px-4 py-3">詳細</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
          {items.map((s) => (
            <tr key={s.submission_id} className="text-zinc-900 dark:text-zinc-100">
              <td className="px-4 py-3 text-zinc-600 dark:text-zinc-400">
                {new Date(s.epoch_second * 1000).toLocaleString("ja-JP")}
              </td>
              <td className="px-4 py-3 font-mono">{s.problem_id}</td>
              <td className="px-4 py-3">
                <ResultBadge result={s.result} />
              </td>
              <td className="px-4 py-3 text-zinc-600 dark:text-zinc-400">
                {s.language}
              </td>
              <td className="px-4 py-3">
                <Link
                  href={`/submissions/${encodeURIComponent(s.submission_id)}`}
                  className="text-blue-600 hover:underline dark:text-blue-400"
                >
                  詳細
                </Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function ResultBadge({ result }: { result: string }) {
  const tone = result === "AC"
    ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300"
    : "bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-300";
  return (
    <span className={`rounded px-2 py-0.5 text-xs font-medium ${tone}`}>
      {result}
    </span>
  );
}
