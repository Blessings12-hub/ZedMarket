// The reply-speed badge. The database works it out from real chats (see seller_reply_speed); a seller cannot type it in.
export type ReplySpeed = 'within_an_hour' | 'within_a_day';

export function toReplySpeed(value: unknown): ReplySpeed | null {
  return value === 'within_an_hour' || value === 'within_a_day' ? value : null;
}

export function replySpeedLabel(speed: ReplySpeed | null): string | null {
  if (speed === 'within_an_hour') return 'Usually replies within an hour';
  if (speed === 'within_a_day') return 'Usually replies within a day';
  return null;
}
