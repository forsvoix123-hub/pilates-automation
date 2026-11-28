import { useState } from "react";
import { matchingSlots, type Slot } from "@/lib/demo";

export function useScheduleFilters(slots: Slot[]) {
  const [date, setDate] = useState("");
  const [trainer, setTrainer] = useState("");
  const trainers = [...new Set(slots.map((slot) => slot.specialist))].sort();
  const specialist = trainers.includes(trainer) ? trainer : "";
  return { date, setDate, specialist, setTrainer, trainers, visible: matchingSlots(slots, date, specialist) };
}

export function ScheduleFilters({ filters, labels }: {
  filters: ReturnType<typeof useScheduleFilters>;
  labels: { date: string; trainer: string; allTrainers: string; reset: string };
}) {
  return (
    <div className="inline-form">
      <label>{labels.date}<input type="date" value={filters.date} onChange={(event) => filters.setDate(event.target.value)} /></label>
      <label>{labels.trainer}<select value={filters.specialist} onChange={(event) => filters.setTrainer(event.target.value)}>
        <option value="">{labels.allTrainers}</option>
        {filters.trainers.map((name) => <option key={name}>{name}</option>)}
      </select></label>
      {(filters.date || filters.specialist) && <button className="button" onClick={() => { filters.setDate(""); filters.setTrainer(""); }}>{labels.reset}</button>}
    </div>
  );
}
