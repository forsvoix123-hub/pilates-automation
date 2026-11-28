const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const { test } = require("node:test");
const React = require("react");
const { renderToStaticMarkup } = require("react-dom/server");
const ts = require("typescript");

function loadSource(path, imports = {}) {
  const source = readFileSync(resolve(__dirname, "..", path), "utf8");
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  });
  const result = {};
  new Function("require", "exports", outputText)((name) => imports[name] ?? require(name), result);
  return result;
}

const domain = loadSource("lib/demo.ts");
const model = loadSource("lib/supabase/model.ts", { "@/lib/demo": domain });

test("the schedule offers the correct repeat action after either cancellation", () => {
  const slot = {
    id: "slot", service: "service", date: "2099-12-03", time: "09:30",
    specialist: "Anna", kind: "group", capacity: 1, occupiedSeats: 0, startsAt: "2099-12-03T08:30:00Z",
  };
  const state = {
    today: "2099-11-29", freeCancellationHours: 12, services: [{ id: "service", direction: "pilates", name: { ru: "Пилатес" } }],
    slots: [slot], clients: [{ id: "client", name: "Клиент" }], memberships: [], bookings: [],
  };
  let tab = "schedule";
  let command;
  const { Studio } = loadSource("components/studio.tsx", {
    react: { ...React, useState: (initial) => [initial === "catalog" ? tab : initial, () => {}] },
    "@/lib/demo": domain,
    "@/lib/supabase/model": model,
    "@/app/auth-actions": { logout() {} },
    "./studio-data": {
      useVisibleStudioRefresh() {},
      useStudioData: () => ({
        state, clientId: "client", busy: false, refreshing: false, refresh() {},
        async save(value) { command = value; return true; },
      }),
    },
    "./schedule-filters": { ScheduleFilters: () => null, useScheduleFilters: (slots) => ({ visible: slots }) },
  });
  const render = () => renderToStaticMarkup(React.createElement(Studio));

  function findButton(node, label) {
    if (Array.isArray(node)) return node.map((item) => findButton(item, label)).find(Boolean);
    if (!React.isValidElement(node)) return undefined;
    if (node.type === "button" && node.props.children === label) return node;
    return findButton(node.props.children, label);
  }

  const pass = { id: "pass", client: "client", name: "Абонемент", direction: "pilates", startsOn: "2099-12-01", expiresOn: "2099-12-31", total: 2, remaining: 1, reserved: 0 };
  assert(findButton(Studio(), "Отправить заявку"));
  state.memberships = [pass];
  assert(findButton(Studio(), "Записаться"));
  for (const [status, label] of [
    ["pending", "Ожидает подтверждения"], ["confirmed", "Вы записаны"], ["attended", "Посещение отмечено"],
  ]) {
    state.bookings = [{ id: "active", client: "client", slot: slot.id, status, cancellationSource: null }];
    assert(findButton(Studio(), label).props.disabled);
  }
  for (const source of ["client", "admin"]) {
    state.bookings = [{ id: "old", client: "client", slot: slot.id, status: "cancelled", cancellationSource: source }];
    state.memberships = [];
    assert(findButton(Studio(), "Подать заявку повторно"));
    state.memberships = [pass];
    const button = findButton(Studio(), "Записаться повторно");
    assert(button && !button.props.disabled);
    button.props.onClick();
    assert.deepEqual(command, { type: "booking", slot: slot.id });
  }

  slot.occupiedSeats = 1;
  assert(findButton(Studio(), "Мест нет").props.disabled);
  slot.occupiedSeats = 0;
  slot.startsAt = "2000-01-01T00:00:00Z";
  assert(findButton(Studio(), "Занятие уже началось").props.disabled);
  slot.cancelled = true;
  assert(!findButton(Studio(), "Записаться повторно"));
  tab = "account";
  assert(render().includes("Осталось занятий: 1 / 2 · В резерве: 0 · Доступно для записи: 1"));

  const { Admin } = loadSource("components/admin.tsx", {
    react: { ...React, useState: (initial) => [initial === "Обзор" ? "Абонементы" : initial, () => {}] },
    "@/lib/demo": domain,
    "@/app/auth-actions": { logout() {} },
    "@/lib/supabase/schedule-time": loadSource("lib/supabase/schedule-time.ts"),
    "./studio-data": {
      useVisibleStudioRefresh() {},
      useStudioData: () => ({ state, busy: false, refreshing: false, refresh() {}, async save() { return true; } }),
    },
    "./schedule-filters": { ScheduleFilters: () => null, useScheduleFilters: (slots) => ({ visible: slots }) },
    "./employees": { Employees: () => null, directions: { pilates: "Пилатес", beauty: "Косметология" } },
  });
  const crm = renderToStaticMarkup(React.createElement(Admin));
  assert(crm.includes("В резерве: 0") && crm.includes("Доступно: 1"));

  tab = "bookings";
  state.bookings = [{
    id: "late", client: "client", slot: slot.id, status: "cancelled", cancellationSource: "client",
    lateCancellation: true, membershipCharged: true, refundedAt: null,
  }];
  assert(render().includes("Поздняя отмена") && render().includes("Списано одно занятие"));
  state.bookings[0].refundedAt = "2099-12-03T08:33:00Z";
  assert(render().includes("Одно занятие возвращено на абонемент"));
});
