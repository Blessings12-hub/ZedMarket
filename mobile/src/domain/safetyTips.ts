// Plain advice on buying and paying safely. ZedMarket does not hold anyone's money while payments are switched off,
// so most of this is about what a buyer and a seller do face to face and on mobile money.

export type SafetySection = { title: string; points: string[] };

export const SAFETY_SECTIONS: SafetySection[] = [
  {
    title: 'Before you pay',
    points: [
      'Look at the item first. Check that it works and matches the photos.',
      'Meet in a public, busy place in daytime. Bring a friend if you can.',
      'Never pay for something you have not seen, even if the seller says others are waiting to buy it.',
      'If the price is far below what the same item usually costs, be careful. Report the listing if it looks wrong.',
    ],
  },
  {
    title: 'Paying with mobile money',
    points: [
      'Pay only when you are holding the item, or when you have collected it.',
      'Check the name and number on your screen before you press send. A sent mobile money payment is hard to get back.',
      'Never share your mobile money PIN, your password or a code sent to your phone with anyone, even someone who says they work for a mobile network, a bank or ZedMarket.',
      'Be careful with a message that says money was sent to you by mistake and asks you to send it back. Check your own balance on your own phone first.',
      'Keep the payment message as proof.',
    ],
  },
  {
    title: 'Chat and records',
    points: [
      'Keep your messages in ZedMarket. If something goes wrong, the record helps us look into it.',
      'Be careful if someone asks you to move to another app straight away, or sends a link to a page asking for your details.',
      'Block anyone who pressures you, and report them from the chat.',
    ],
  },
  {
    title: 'If something goes wrong',
    points: [
      'Open the order and choose Report a problem, or use Help to message our team.',
      'Report a listing or a person from their page. Our team looks at every report.',
      'For fraud or a threat to your safety, also tell the police.',
    ],
  },
];
