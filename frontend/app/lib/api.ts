// Backend API クライアント
// 設計の根拠: docs/learning/phase1/practice/frontend-api-client.md

import { fetchAuthSession } from "aws-amplify/auth";
import type {
  ApiError,
  ApiSuccess,
  Submission,
  SyncResult,
  User,
} from "./types";

export class ApiCallError extends Error {
  constructor(
    public code: string,
    message: string,
    public status: number,
  ) {
    super(message);
    this.name = "ApiCallError";
  }
}

async function getIdToken(): Promise<string> {
  // Amplify v6: idToken をサーバ (API Gateway Cognito Authorizer) が検証する
  const session = await fetchAuthSession();
  const token = session.tokens?.idToken?.toString();
  if (!token) {
    throw new ApiCallError("NOT_AUTHENTICATED", "ログインが必要です", 401);
  }
  return token;
}

async function apiFetch<T>(
  path: string,
  init: RequestInit = {},
): Promise<{ data: T; meta: Record<string, unknown> | null }> {
  const baseUrl = process.env.NEXT_PUBLIC_API_URL;
  if (!baseUrl) {
    throw new Error("NEXT_PUBLIC_API_URL is not set");
  }

  const token = await getIdToken();

  const res = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...(init.headers ?? {}),
    },
  });

  const json = await res.json();

  if (!res.ok) {
    const err = json as ApiError;
    throw new ApiCallError(
      err.error?.code ?? "UNKNOWN",
      err.error?.message ?? "Unknown error",
      res.status,
    );
  }

  const ok = json as ApiSuccess<T>;
  return { data: ok.data, meta: ok.meta };
}

// =====================================================================
// 公開 API (1 ハンドラ 1 関数)
// =====================================================================

export const api = {
  saveAtcoderUsername: async (atcoderUsername: string): Promise<User> => {
    const { data } = await apiFetch<User>("/users/me", {
      method: "POST",
      body: JSON.stringify({ atcoder_username: atcoderUsername }),
    });
    return data;
  },

  syncSubmissions: async (): Promise<SyncResult> => {
    const { data } = await apiFetch<SyncResult>("/sync", { method: "POST" });
    return data;
  },

  listSubmissions: async (
    params?: { limit?: number; nextToken?: string },
  ): Promise<{ items: Submission[]; nextToken: string | null }> => {
    const qs = new URLSearchParams();
    if (params?.limit) qs.set("limit", String(params.limit));
    if (params?.nextToken) qs.set("nextToken", params.nextToken);
    const suffix = qs.toString() ? `?${qs}` : "";

    const { data, meta } = await apiFetch<Submission[]>(
      `/submissions${suffix}`,
    );
    return {
      items: data,
      nextToken: (meta?.nextToken as string | null | undefined) ?? null,
    };
  },

  getSubmission: async (submissionId: string): Promise<Submission> => {
    const { data } = await apiFetch<Submission>(
      `/submissions/${encodeURIComponent(submissionId)}`,
    );
    return data;
  },
};
