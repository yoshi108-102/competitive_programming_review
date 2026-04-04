"use client";

import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";

export default function AuthGuard({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <Authenticator hideSignUp>
      {children}
    </Authenticator>
  );
}
