// Supabase errors are plain objects with a message, not Error instances.
// Messages written in our own database functions are already readable and pass through.
// Anything that looks technical is replaced.
export function friendlyError(error: unknown): string {
  let message = '';
  if (error instanceof Error) message = error.message;
  else if (typeof error === 'object' && error !== null && 'message' in error) {
    message = String((error as { message: unknown }).message);
  }

  if (!message) return 'Something went wrong. Please try again.';
  if (/network request failed|failed to fetch|fetch failed/i.test(message)) {
    return 'Check your internet connection and try again.';
  }
  if (/row-level security|permission denied|jwt/i.test(message)) {
    return 'You do not have permission to do that.';
  }
  if (/duplicate key|violates|syntax|relation |column /i.test(message)) {
    return 'Something went wrong. Please try again.';
  }
  return message;
}
