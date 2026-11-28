"use client";

import { useState } from "react";
import type { StudioSchedule, Direction, Employee } from "@/lib/demo";
import { useStudioData } from "./studio-data";

export const directions = { pilates: "Пилатес", beauty: "Косметология" };

function EmployeeForm({ employee, services, onSave, onClose }: {
  employee?: Employee;
  services: StudioSchedule["services"];
  onSave: (employee: Employee) => Promise<boolean>;
  onClose: () => void;
}) {
  const [direction, setDirection] = useState<Direction>(employee?.direction ?? "pilates");
  return (
    <form className="inline-form" onSubmit={async (event) => {
      event.preventDefault();
      const form = event.currentTarget;
      const data = new FormData(form);
      const saved = await onSave({
        id: employee?.id ?? crypto.randomUUID(), name: String(data.get("name")).trim(),
        direction, serviceIds: data.getAll("services").map(String), active: employee?.active ?? true,
      });
      if (saved && !employee) {
        form.reset();
        setDirection("pilates");
      }
    }}>
      <label>Имя сотрудника<input name="name" required defaultValue={employee?.name} /></label>
      <label>Направление<select value={direction} onChange={(event) => setDirection(event.target.value as Direction)}>
        <option value="pilates">{directions.pilates}</option><option value="beauty">{directions.beauty}</option>
      </select></label>
      <fieldset key={direction} className="grid gap-1">
        <legend>Услуги</legend>
        {services.filter((service) => service.direction === direction).map((service) => (
          <label className="flex! items-center" key={service.id}><input name="services" type="checkbox" className="min-h-0!" value={service.id} defaultChecked={employee?.serviceIds.includes(service.id)} />{service.name.ru}</label>
        ))}
      </fieldset>
      <button className="button">{employee ? "Сохранить сотрудника" : "Добавить сотрудника"}</button>
      {employee && <button type="button" className="button" onClick={onClose}>Закрыть редактирование</button>}
    </form>
  );
}

export function Employees({ state, setNotice }: { state: StudioSchedule; setNotice: (message: string) => void }) {
  const { save } = useStudioData();
  const [editing, setEditing] = useState<string>();
  const employee = state.employees.find((item) => item.id === editing);
  return (
    <>
      <EmployeeForm key={employee?.id ?? "new"} employee={employee} services={state.services} onClose={() => setEditing(undefined)} onSave={async (updated) => {
        setNotice("");
        if (!updated.name || !updated.serviceIds.length) {
          setNotice("Укажите имя и выберите хотя бы одну услугу.");
          return false;
        }
        const saved = await save({ type: "employee", employee: updated, editing: Boolean(employee) });
        if (saved) {
          setNotice("Сотрудник сохранён.");
          setEditing(undefined);
        }
        return saved;
      }} />
      <div className="table-wrap">
        <table>
          <thead><tr>{["Имя", "Специализация", "Услуги", "Статус", "Действия"].map((label) => <th scope="col" key={label}>{label}</th>)}</tr></thead>
          <tbody>
            {state.employees.map((item) => <tr key={item.id}>
              <td>{item.name}</td><td>{item.direction === "pilates" ? "Тренер" : "Косметолог"}</td>
              <td>{state.services.filter((service) => item.serviceIds.includes(service.id)).map((service) => service.name.ru).join(", ")}</td>
              <td>{item.active ? "Активен" : "Неактивен"}</td>
              <td><div className="flex flex-wrap gap-2">
                <button className="button" onClick={() => { setEditing(item.id); setNotice(""); }}>Редактировать</button>
                <button className="button" onClick={async () => {
                  setNotice("");
                  const saved = await save({ type: "employee-status", id: item.id, active: !item.active });
                  if (saved) {
                    if (editing === item.id) setEditing(undefined);
                    setNotice(item.active ? "Сотрудник деактивирован." : "Сотрудник активирован.");
                  }
                }}>{item.active ? "Деактивировать" : "Активировать"}</button>
              </div></td>
            </tr>)}
          </tbody>
        </table>
      </div>
    </>
  );
}
