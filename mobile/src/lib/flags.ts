import AsyncStorage from '@react-native-async-storage/async-storage';

// Small yes/no answers kept on the phone, such as "has seen the welcome screens". Reading or writing can fail (private
// browsing, full storage), so nothing here ever throws: a key never saved reads as false, and a failed read reads as null.
export async function getFlag(key: string): Promise<boolean | null> {
  try {
    const v = await AsyncStorage.getItem(`zm.${key}`);
    return v === '1';
  } catch {
    return null;
  }
}

export async function setFlag(key: string, value: boolean): Promise<void> {
  try {
    await AsyncStorage.setItem(`zm.${key}`, value ? '1' : '0');
  } catch {
    // Not saved. The person may see the same notice again, which is harmless.
  }
}
