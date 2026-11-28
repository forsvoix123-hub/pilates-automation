"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { loadStudio, updateStudio } from "@/app/studio-actions";
import type { StudioCommand, StudioData } from "@/lib/supabase/model";

const StudioContext = createContext<{
  state: StudioData; clientId?: string; busy: boolean; refreshing: boolean;
  refresh: (background?: boolean) => Promise<void>;
  save: (command: StudioCommand) => Promise<boolean>;
} | null>(null);

export function useStudioData() {
  const context = useContext(StudioContext);
  if (!context) throw new Error("Missing StudioData provider");
  return context;
}

export function useVisibleStudioRefresh(enabled: boolean, refresh: (background?: boolean) => Promise<void>) {
  useEffect(() => {
    if (!enabled) return;
    const refreshVisible = () => {
      if (document.visibilityState === "visible") void refresh(true);
    };
    const timer = window.setInterval(refreshVisible, 15_000);
    document.addEventListener("visibilitychange", refreshVisible);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", refreshVisible);
    };
  }, [enabled, refresh]);
}

export function StudioDataProvider({ admin = false, children }: { admin?: boolean; children: ReactNode }) {
  const [snapshot, setSnapshot] = useState<{ data: StudioData; clientId?: string }>();
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [refreshing, setRefreshing] = useState(true);
  const saving = useRef(false);
  const reading = useRef(false);
  const loadVersion = useRef(0);

  const reload = useCallback(async (background = false) => {
    const version = ++loadVersion.current;
    try {
      const result = await loadStudio(admin);
      if (version !== loadVersion.current) return false;
      if (result.data) {
        setSnapshot({ data: result.data, clientId: result.clientId });
        return true;
      }
      if (result.denied) setSnapshot(undefined);
      if (result.denied || !background) setMessage(result.error ?? "Не удалось загрузить данные.");
    } catch {
      if (version === loadVersion.current && !background) setMessage("Нет связи с сервером. Повторите попытку.");
    }
    return false;
  }, [admin]);

  const refresh = useCallback(async (background = false) => {
    if (saving.current || reading.current) return;
    reading.current = true;
    setRefreshing(true);
    if (!background) setMessage("");
    try {
      await reload(background);
    } finally {
      reading.current = false;
      setRefreshing(false);
    }
  }, [reload]);

  useEffect(() => {
    const initialRefresh = window.setTimeout(() => void refresh(), 0);
    const refreshOnFocus = () => void refresh(true);
    window.addEventListener("focus", refreshOnFocus);
    return () => {
      window.clearTimeout(initialRefresh);
      window.removeEventListener("focus", refreshOnFocus);
    };
  }, [refresh]);

  async function save(command: StudioCommand) {
    if (saving.current) return false;
    saving.current = true;
    // Discard a background snapshot that began before this mutation.
    ++loadVersion.current;
    setBusy(true);
    setMessage("");
    try {
      const error = await updateStudio(command);
      if (error) {
        if (command.type === "booking" || command.type === "booking-status") await reload();
        setMessage(error);
        return false;
      }
      if (!await reload()) setMessage("Изменение сохранено. Обновите данные, чтобы увидеть результат.");
      return true;
    } catch {
      setMessage("Ответ сервера не получен. Обновите данные перед повторной попыткой.");
      return false;
    } finally {
      saving.current = false;
      setBusy(false);
    }
  }

  return (
    <>
      {(message || busy || (!snapshot && refreshing)) && <div className="frame py-2">
        {(busy || (!snapshot && refreshing)) && <p role="status">{snapshot ? "Обновление данных…" : "Загрузка данных студии…"}</p>}
        {message && <div className="flex flex-wrap items-center gap-3">
          <p role="alert">{message}</p><button className="button" disabled={busy || refreshing} onClick={() => void refresh()}>Обновить</button>
          {!snapshot && <a className="contact-link" href={admin ? "/login?next=admin" : "/login"}>Войти снова</a>}
        </div>}
      </div>}
      {snapshot && <StudioContext.Provider value={{ state: snapshot.data, clientId: snapshot.clientId, busy, refreshing, refresh, save }}>{children}</StudioContext.Provider>}
    </>
  );
}
