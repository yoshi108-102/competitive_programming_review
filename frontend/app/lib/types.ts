// Backend `shared/response.py::success/error` の戻り値を TypeScript で表現
// → docs/learning/phase1/practice/shared-response-helper-design.md

export type ApiSuccess<T> = {
  data: T;
  meta: Record<string, unknown> | null;
};

export type ApiError = {
  error: {
    code: string;
    message: string;
  };
};

// ドメイン型 (DynamoDB の item 形)
// score / point は Decimal が default=str で文字列化されているため string
// → docs/learning/phase1/practice/json-dumps-default-str.md
export type Submission = {
  user_id: string;
  submission_id: string;
  problem_id: string;
  contest_id: string;
  language: string;
  point: string;
  length: number;
  result: string;
  execution_time: number | null;
  epoch_second: number;
};

export type User = {
  user_id: string;
  atcoder_username: string;
  last_sync_epoch?: number;
};

export type SyncResult = {
  synced_count: number;
  from_second: number;
};
