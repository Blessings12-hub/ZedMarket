import { Redirect, Slot } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { ConsoleShell } from '../../src/components/ConsoleShell';
import { staffAccessStep, type AdminRole } from '../../src/domain/admin';
import { fetchAssurance, fetchMyRoles } from '../../src/features/admin/api';
import { colors } from '../../src/theme';

// The console is for staff who have finished two-factor sign-in. Anyone else is sent to the staff sign-in page,
// which explains what is missing. The database still checks every action on its own.
export default function ConsoleLayout() {
  const { userId } = useAuth();
  const [roles, setRoles] = useState<AdminRole[]>([]);
  const [ready, setReady] = useState<boolean | null>(null);

  useEffect(() => {
    if (!userId) return;
    Promise.all([fetchMyRoles(userId), fetchAssurance()])
      .then(([r, level]) => {
        setRoles(r);
        setReady(staffAccessStep(r, level.currentLevel, level.nextLevel) === 'ready');
      })
      .catch(() => setReady(false));
  }, [userId]);

  if (ready === null) {
    return <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background }}><ActivityIndicator color={colors.primary} /></View>;
  }
  if (!ready) return <Redirect href="/admin" />;
  return <ConsoleShell roles={roles}><Slot /></ConsoleShell>;
}
