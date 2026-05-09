"use client";

import Link from "next/link";
import { useAuthenticator } from "@aws-amplify/ui-react";

// 共通レイアウト: ヘッダ + ナビゲーション + ログアウト
// 各ページの children を main 内に描画する。
// → docs/learning/phase1/task12/01-nextjs-client-page-with-auth-and-api.md
export default function AppShell({
  children,
}: {
  children: React.ReactNode;
}) {
  const { user, signOut } = useAuthenticator();

  return (
    <div className="flex flex-col flex-1 bg-zinc-50 font-sans dark:bg-zinc-950">
      <header className="border-b border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-6">
            <Link
              href="/"
              className="text-lg font-semibold text-zinc-900 dark:text-zinc-50"
            >
              AtCoder Review
            </Link>
            <nav className="flex items-center gap-4 text-sm">
              <Link
                href="/submissions"
                className="text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-zinc-50"
              >
                提出一覧
              </Link>
              <Link
                href="/settings"
                className="text-zinc-600 hover:text-zinc-900 dark:text-zinc-300 dark:hover:text-zinc-50"
              >
                設定
              </Link>
            </nav>
          </div>
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

      <main className="mx-auto w-full max-w-5xl flex-1 px-6 py-8">
        {children}
      </main>
    </div>
  );
}
