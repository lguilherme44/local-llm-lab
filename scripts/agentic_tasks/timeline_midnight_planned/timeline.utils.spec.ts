import { describe, it, expect } from "./harness.ts";
import { buildDayTimeline } from "./timeline.utils.ts";

describe("buildDayTimeline", () => {
  it("classifies slots as FREE, BUSY, LUNCH and UNAVAILABLE", () => {
    const timeline = buildDayTimeline({
      startTime: "09:00",
      endTime: "12:00",
      lunchStartTime: "10:00",
      lunchEndTime: "10:30",
      slotIntervalMinutes: 30,
      appointments: [{ startTime: "09:30", endTime: "10:10" }],
      availableSlots: [
        { startTime: "09:00", available: true },
        { startTime: "10:30", available: true },
      ],
    });

    expect(timeline).toEqual([
      { startTime: "09:00", endTime: "09:30", status: "FREE" },
      { startTime: "09:30", endTime: "10:00", status: "BUSY" },
      { startTime: "10:00", endTime: "10:30", status: "LUNCH" },
      { startTime: "10:30", endTime: "11:00", status: "FREE" },
      { startTime: "11:00", endTime: "11:30", status: "UNAVAILABLE" },
      { startTime: "11:30", endTime: "12:00", status: "UNAVAILABLE" },
    ]);
  });

  it("returns an empty list when schedule range is invalid", () => {
    const timeline = buildDayTimeline({
      startTime: "14:00",
      endTime: "14:00",
      appointments: [],
      availableSlots: [],
    });

    expect(timeline).toEqual([]);
  });

  it("keeps an appointment that runs to midnight visible after closing time", () => {
    const timeline = buildDayTimeline({
      startTime: "22:00",
      endTime: "23:30",
      slotIntervalMinutes: 30,
      appointments: [{ startTime: "23:30", endTime: "00:00" }],
      availableSlots: [
        { startTime: "22:00", available: true },
        { startTime: "22:30", available: true },
        { startTime: "23:00", available: true },
      ],
    });

    expect(timeline).toEqual([
      { startTime: "22:00", endTime: "22:30", status: "FREE" },
      { startTime: "22:30", endTime: "23:00", status: "FREE" },
      { startTime: "23:00", endTime: "23:30", status: "FREE" },
      { startTime: "23:30", endTime: "00:00", status: "BUSY" },
    ]);
  });

  it("treats a schedule that closes at midnight as end of day", () => {
    const timeline = buildDayTimeline({
      startTime: "23:00",
      endTime: "00:00",
      slotIntervalMinutes: 30,
      appointments: [],
      availableSlots: [
        { startTime: "23:00", available: true },
        { startTime: "23:30", available: true },
      ],
    });

    expect(timeline).toEqual([
      { startTime: "23:00", endTime: "23:30", status: "FREE" },
      { startTime: "23:30", endTime: "00:00", status: "FREE" },
    ]);
  });

  it("classifies blocked ranges as LOCKED", () => {
    const timeline = buildDayTimeline({
      startTime: "09:00",
      endTime: "10:00",
      appointments: [],
      availableSlots: [
        { startTime: "09:00", available: true },
        { startTime: "09:30", available: true },
      ],
      blocks: [{ id: "block-1", startTime: "09:30", endTime: "10:00" }],
    });

    expect(timeline).toEqual([
      { startTime: "09:00", endTime: "09:30", status: "FREE" },
      {
        startTime: "09:30",
        endTime: "10:00",
        status: "LOCKED",
        blockId: "block-1",
      },
    ]);
  });
});
