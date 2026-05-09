"use client";

import Link from "next/link";

// ホーム = 簡易ダッシュボード。提出一覧と設定への入口。
export default function Home() {
  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
          ようこそ
        </h2>
        <p className="mt-2 text-zinc-600 dark:text-zinc-400">
          初回はまず設定で AtCoder のユーザー名を登録してください。
          その後、提出一覧から同期と閲覧ができます。
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Link
          href="/settings"
          className="rounded-lg border border-zinc-200 bg-white p-6 transition-colors hover:border-zinc-300 hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-zinc-700 dark:hover:bg-zinc-800"
        >
          <h3 className="font-semibold text-zinc-900 dark:text-zinc-50">
            設定
          </h3>
          <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            AtCoder のユーザー名を登録 / 変更
          </p>
        </Link>
        <Link
          href="/submissions"
          className="rounded-lg border border-zinc-200 bg-white p-6 transition-colors hover:border-zinc-300 hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-zinc-700 dark:hover:bg-zinc-800"
        >
          <h3 className="font-semibold text-zinc-900 dark:text-zinc-50">
            提出一覧
          </h3>
          <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            AtCoder の提出を同期 / 閲覧
          </p>
        </Link>
      </div>
    </div>
  );
}
