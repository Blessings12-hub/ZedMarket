// Invite codes are 8 characters from an alphabet without look-alikes (no 0, O, 1, I). The database checks them again.
const CODE = /^[A-HJ-NP-Z2-9]{8}$/;

export function cleanInviteCode(input: string): string {
  return input.replace(/[\s-]/g, '').toUpperCase();
}

export function isInviteCode(input: string): boolean {
  return CODE.test(cleanInviteCode(input));
}

export function inviteMessage(code: string, link: string | null): string {
  const head = `Join me on ZedMarket, a marketplace for buying and selling in Zambia. After you sign up, enter my invite code ${code}.`;
  return link ? `${head}\n${link}` : head;
}
