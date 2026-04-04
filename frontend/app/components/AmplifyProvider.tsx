"use client";

import { Amplify } from "aws-amplify";
import amplifyConfig from "@/app/lib/amplify-config";

Amplify.configure(amplifyConfig, { ssr: false });

export default function AmplifyProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  return <>{children}</>;
}
