"use client";

import { useAuthenticator } from "@aws-amplify/ui-react";

export default function Home() {
  const { user, signOut } = useAuthenticator();

  return (
    <div className="flex flex-col flex-1 bg-zinc-50 font-sans dark:bg-zinc-950">
      {/* Header */}
      <header className="border-b border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <h1 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">
            AtCoder Review
          </h1>
          <div className="flex items-center gap-4">
            <span className="text-sm text-zinc-500 dark:text-zinc-400">
              {user?.signInDetails?.loginId}
            </span>
            <button
              onClick={signOut}
              className="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700"
            >
              ログアウト
            </button>
          </div>
        </div>
      </header>

      {/* Main */}
      <main className="mx-auto w-full max-w-5xl flex-1 px-6 py-8">
        <div className="rounded-lg border border-zinc-200 bg-white p-8 dark:border-zinc-800 dark:bg-zinc-900">
          <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">
            ダッシュボード
          </h2>
          <p className="mt-2 text-zinc-600 dark:text-zinc-400">
            ログインに成功しました。提出履歴の取得機能は次のマイルストーンで実装予定です。
          </p>
        </div>
      </main>
    </div>
  );
}
