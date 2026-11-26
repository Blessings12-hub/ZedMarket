// Supabase errors are plain objects with a message, not Error instances.
// Messages written in our own database functions are already readable and pass through.
// Anything that looks technical is replaced.
export function friendlyError(error: unknown): string {
  let message = '';
  if (error instanceof Error) message = error.message;
  else if (typeof error === 'object' && error !== null && 'message' in error) {
    message = String((error as { message: unknown }).message);
  }

  const code = typeof error === 'object' && error !== null && 'code' in error ? String((error as { code: unknown }).code) : '';

  if (!message) return 'Something went wrong. Please try again.';
  // The database function the app asked for is not there (an update has not been applied yet).
  if (code === 'PGRST202' || code === '42883' || /could not find the function/i.test(message)) {
    return 'This part of ZedMarket is being updated. Please try again in a few minutes.';
  }
  if (/timed out|timeout|aborted/i.test(message)) {
    return 'The connection is slow right now. Please try again in a moment.';
  }
  if (/network request failed|failed to fetch|fetch failed|load failed|networkerror/i.test(message)) {
    return 'Check your internet connection and try again.';
  }
  if (/HTTP (502|503|504)|bad gateway|service unavailable|gateway time-?out/i.test(message)) {
    return 'ZedMarket is busy or the network dropped. Please try again in a moment.';
  }
  if (/row-level security|permission denied|jwt/i.test(message)) {
    return 'You do not have permission to do that.';
  }
  if (/violates check constraint/i.test(message)) {
    return 'One of your answers is too short or too long. Please check your answers and try again.';
  }
  if (/duplicate key|violates|syntax|relation |column /i.test(message)) {
    return 'Something went wrong. Please try again.';
  }
  return message;
}
