import React, { useState } from "react";
import { api, setToken } from "../api.js";

export default function Login({ onSuccess }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    if (!password || busy) return;
    setBusy(true);
    setError(null);
    try {
      const { token } = await api.login(password);
      setToken(token);
      onSuccess();
    } catch (err) {
      setError(err.message || "Sign in failed.");
      setBusy(false);
    }
  }

  return (
    <div className="centered">
      <form className="card login" onSubmit={submit}>
        <div className="brand">✦ AI Stock Studio</div>
        <h1>Portfolio dashboard</h1>
        <p className="sub">Enter the dashboard password to view the portfolio.</p>
        <input
          type="password"
          inputMode="text"
          autoComplete="current-password"
          placeholder="Password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoFocus
        />
        {error && <div className="error">{error}</div>}
        <button type="submit" disabled={busy || !password}>
          {busy ? "Signing in…" : "View dashboard"}
        </button>
        <div className="footnote">Read-only · data is not editable here</div>
      </form>
    </div>
  );
}
