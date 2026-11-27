import 'react-native-url-polyfill/auto';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL;
const anonKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;

// When the two settings are missing the app must not crash at start-up (on the web that is a blank white page). It starts,
// the root layout sees this flag and shows a clear "not set up" screen, and nothing tries to reach a database.
export const supabaseConfigured = Boolean(url && anonKey);

export const supabase = createClient(url || 'https://not-configured.invalid', anonKey || 'not-configured', {
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});

export function listingImageUrl(path: string): string {
  return supabase.storage.from('listing-images').getPublicUrl(path).data.publicUrl;
}
