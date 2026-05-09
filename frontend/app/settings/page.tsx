"use client";

import { FormEvent, useState } from "react";
import { ApiCallError, api } from "@/app/lib/api";

export default function SettingsPage() {
  const [username, setUsername] = useState("");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    setError(null);

    try {
      const user = await api.saveAtcoderUsername(username.trim());
      setMessage(`保存しました: ${user.atcoder_username}`);
    } catch (err) {
      setError(
        err instanceof ApiCallError ? err.message : "保存に失敗しました",
      );
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
          設定
        </h2>
        <p className="mt-2 text-zinc-600 dark:text-zinc-400">
          AtCoder のユーザー名を登録します。提出履歴の同期に使われます。
        </p>

        <form onSubmit={onSubmit} className="mt-6 space-y-4">
          <div>
            <label
              htmlFor="atcoder-username"
              className="block text-sm font-medium text-zinc-700 dark:text-zinc-300"
            >
              AtCoder ユーザー名
            </label>
            <input
              id="atcoder-username"
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="chokudai"
              disabled={saving}
              className="mt-1 block w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-50"
            />
          </div>

          <button
            type="submit"
            disabled={saving || !username.trim()}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            {saving ? "保存中..." : "保存"}
          </button>

          {message && (
            <p className="text-sm text-green-600 dark:text-green-400">
              {message}
            </p>
          )}
          {error && (
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          )}
        </form>
      </div>
    </div>
  );
}
