import React, { useEffect, useState } from "react";
import { api, getToken, clearToken } from "./api.js";
import Login from "./components/Login.jsx";
import Dashboard from "./components/Dashboard.jsx";

export default function App() {
  const [authed, setAuthed] = useState(!!getToken());
  const [gateEnabled, setGateEnabled] = useState(null); // null = unknown yet

  useEffect(() => {
    api
      .config()
      .then((c) => setGateEnabled(c.enabled))
      .catch(() => setGateEnabled(true)); // assume gated on error — fail safe
  }, []);

  function signOut() {
    clearToken();
    setAuthed(false);
  }

  if (gateEnabled === false) {
    // Dashboard not enabled on the backend (WEB_DASHBOARD_PASSWORD unset).
    return (
      <div className="centered">
        <div className="card notice">
          <h1>Dashboard not enabled</h1>
          <p>
            Set <code>WEB_DASHBOARD_PASSWORD</code> on the backend to turn on the
            read-only web dashboard.
          </p>
        </div>
      </div>
    );
  }

  if (!authed) {
    return <Login onSuccess={() => setAuthed(true)} />;
  }

  return <Dashboard onSignOut={signOut} />;
}
