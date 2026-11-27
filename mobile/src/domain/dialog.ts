// What a pop-up should do on the web. React Native's Alert does nothing in a browser, so anything that asked a question
// through it (confirm an order, delete an address, sign in to continue) silently did nothing and every error message
// vanished. On the web the browser's own boxes are used instead. Kept apart from React Native so it can be tested.

export type DialogButton = { text: string; style?: 'default' | 'cancel' | 'destructive'; onPress?: () => void | Promise<void> };

export function runWebDialog(
  title: string,
  message: string | undefined,
  buttons: DialogButton[] | undefined,
  ask: (text: string) => boolean,
  tell: (text: string) => void,
): void {
  const text = message ? `${title}\n\n${message}` : title;
  const all = buttons ?? [];
  const cancel = all.find((b) => b.style === 'cancel');
  const actions = all.filter((b) => b.style !== 'cancel');

  // A plain message: show it, then run the one button if there is one.
  if (all.length <= 1) {
    tell(text);
    void all[0]?.onPress?.();
    return;
  }
  // A question: the first action the person agrees to runs. Cancelling runs the cancel button.
  for (const action of actions) {
    const prompt = `${text}\n\nOK: ${action.text}\nCancel: ${cancel?.text ?? 'Go back'}`;
    if (ask(prompt)) {
      void action.onPress?.();
      return;
    }
  }
  void cancel?.onPress?.();
}
