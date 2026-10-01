/**
 * The OTP path's clock. Production reads the wall clock; the fraud replay and tests swap it so a
 * simulated week runs in minutes. Every time the OTP start and check paths compare against, in
 * TypeScript or in SQL, comes from here rather than from Date.now() or now().
 */
let current: () => Date = () => new Date();

export function otpNow(): Date {
  return current();
}

/** Pass null to restore the wall clock. */
export function setOtpClock(clock: (() => Date) | null): void {
  current = clock ?? (() => new Date());
}
