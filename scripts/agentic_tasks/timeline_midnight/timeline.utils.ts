export type TimelineSlotStatus =
  | "FREE"
  | "BUSY"
  | "LUNCH"
  | "LOCKED"
  | "UNAVAILABLE"
  | "COMPLETED"
  | "NO_SHOW";

export interface TimelineSlot {
  startTime: string;
  endTime: string;
  status: TimelineSlotStatus;
  blockId?: string;
  busyMeta?: {
    appointmentId?: string;
    customerId?: string;
    customerName?: string;
    customerPhone?: string;
    serviceName?: string;
    professionalName?: string;
    appointmentStatus?: string;
    planUsagePreview?: {
      planName: string;
      includedQuantity: number;
      usedQuantity?: number;
      remainingQuantity: number;
      deducted: boolean;
    } | null;
  };
}

interface TimeRange {
  startTime: string;
  endTime: string;
}

interface BusyAppointment extends TimeRange {
  id?: string;
  customerId?: string;
  customerName?: string;
  customerPhone?: string;
  serviceName?: string;
  professionalName?: string;
  planUsagePreview?: {
    planName: string;
    includedQuantity: number;
    usedQuantity?: number;
    remainingQuantity: number;
    deducted: boolean;
  } | null;
  status?: string;
}

interface AvailableSlot {
  startTime: string;
  available: boolean;
}

export interface BuildDayTimelineInput {
  startTime: string;
  endTime: string;
  lunchStartTime?: string;
  lunchEndTime?: string;
  slotIntervalMinutes?: number;
  appointments: BusyAppointment[];
  blocks?: Array<TimeRange & { id?: string }>;
  availableSlots: AvailableSlot[];
}

function timeToMinutes(time: string): number {
  const [hours, minutes] = time.split(":").map(Number);
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) {
    return Number.NaN;
  }

  return hours * 60 + minutes;
}

function minutesToTime(minutes: number): string {
  const hours = Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0");
  const mins = (minutes % 60).toString().padStart(2, "0");
  return `${hours}:${mins}`;
}

function overlaps(
  startA: string,
  endA: string,
  startB: string,
  endB: string,
): boolean {
  const startAMin = timeToMinutes(startA);
  const endAMin = timeToMinutes(endA);
  const startBMin = timeToMinutes(startB);
  const endBMin = timeToMinutes(endB);

  return startAMin < endBMin && startBMin < endAMin;
}

export function buildDayTimeline(input: BuildDayTimelineInput): TimelineSlot[] {
  const startMinutes = timeToMinutes(input.startTime);
  const endMinutes = timeToMinutes(input.endTime);
  const slotInterval = input.slotIntervalMinutes ?? 30;

  if (
    !Number.isFinite(startMinutes) ||
    !Number.isFinite(endMinutes) ||
    slotInterval <= 0 ||
    startMinutes >= endMinutes
  ) {
    return [];
  }

  const availableSet = new Set(
    input.availableSlots
      .filter((slot) => slot.available)
      .map((slot) => slot.startTime),
  );

  const hasLunchRange =
    !!input.lunchStartTime &&
    !!input.lunchEndTime &&
    timeToMinutes(input.lunchStartTime) < timeToMinutes(input.lunchEndTime);

  const timeline: TimelineSlot[] = [];

  for (
    let current = startMinutes;
    current + slotInterval <= endMinutes;
    current += slotInterval
  ) {
    const slotStart = minutesToTime(current);
    const slotEnd = minutesToTime(current + slotInterval);

    const isLunch =
      hasLunchRange &&
      overlaps(slotStart, slotEnd, input.lunchStartTime!, input.lunchEndTime!);

    const matchingAppointment = input.appointments.find((appointment) =>
      overlaps(slotStart, slotEnd, appointment.startTime, appointment.endTime),
    );
    const isBusy = !!matchingAppointment;
    const matchingBlock = (input.blocks ?? []).find((block) =>
      overlaps(slotStart, slotEnd, block.startTime, block.endTime),
    );

    let status: TimelineSlotStatus = "UNAVAILABLE";

    if (isLunch) {
      status = "LUNCH";
    } else if (isBusy) {
      status = "BUSY";
    } else if (matchingBlock) {
      status = "LOCKED";
    } else if (availableSet.has(slotStart)) {
      status = "FREE";
    }

    if (isBusy && matchingAppointment?.status === "COMPLETED") {
      status = "COMPLETED";
    } else if (isBusy && matchingAppointment?.status === "NO_SHOW") {
      status = "NO_SHOW";
    }

    timeline.push({
      startTime: slotStart,
      endTime: slotEnd,
      status,
      blockId: matchingBlock?.id,
      busyMeta:
        matchingAppointment &&
        (matchingAppointment.id ||
          matchingAppointment.customerName ||
          matchingAppointment.customerPhone ||
          matchingAppointment.professionalName ||
          matchingAppointment.serviceName)
          ? {
              appointmentId: matchingAppointment.id,
              customerId: matchingAppointment.customerId,
              customerName: matchingAppointment.customerName,
              customerPhone: matchingAppointment.customerPhone,
              serviceName: matchingAppointment.serviceName,
              professionalName: matchingAppointment.professionalName,
              appointmentStatus: matchingAppointment.status,
              planUsagePreview: matchingAppointment.planUsagePreview,
            }
          : undefined,
    });
  }

  return timeline;
}
