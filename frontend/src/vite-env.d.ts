/// <reference types="vite/client" />

interface ImportMetaEnv {
  // Absolute backend URL for production builds (e.g. https://api.example.com).
  // Unset in dev, where Vite's proxy forwards /api to the local backend.
  readonly VITE_API_BASE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
