import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useState } from 'react';

import { addToCart, parseCart, removeFromCart, type CartItem } from '../../domain/cart';

// The cart lives on the phone (one per signed-in user, or one for a visitor) and is never sent anywhere
// until the buyer requests an item at checkout.
const KEY = 'zedmarket.cart.v1';

let items: CartItem[] = [];
let loaded = false;
const listeners = new Set<(c: CartItem[]) => void>();

function publish() {
  listeners.forEach((l) => l(items));
}

async function persist() {
  try {
    await AsyncStorage.setItem(KEY, JSON.stringify(items));
  } catch {
    /* the cart still works for this session if storage fails */
  }
}

async function ensureLoaded() {
  if (loaded) return;
  loaded = true;
  try {
    items = parseCart(await AsyncStorage.getItem(KEY));
  } catch {
    items = [];
  }
  publish();
}

export async function addItem(item: CartItem) {
  await ensureLoaded();
  items = addToCart(items, item);
  publish();
  await persist();
}

export async function removeItem(listingId: string) {
  await ensureLoaded();
  items = removeFromCart(items, listingId);
  publish();
  await persist();
}

export function useCart(): CartItem[] {
  const [state, setState] = useState<CartItem[]>(items);
  useEffect(() => {
    listeners.add(setState);
    void ensureLoaded().then(() => setState(items));
    return () => {
      listeners.delete(setState);
    };
  }, []);
  return state;
}
