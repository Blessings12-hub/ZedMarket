import { useState } from 'react';
import { Text } from 'react-native';

import { Button, Field, Notice } from '../../src/components/ui';
import { fetchPerformance, fetchPermissions, recordPerformance } from '../../src/features/media/api';
import { has } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { friendlyError } from '../../src/lib/errors';

export default function Performance() {
  const perms = useLoad(fetchPermissions);
  const list = useLoad(fetchPerformance);
  const [open, setOpen] = useState<string | null>(null);
  const [imp, setImp] = useState('');
  const [clk, setClk] = useState('');
  const [eng, setEng] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const p = perms.data ?? [];
  const num = (v: string) => (/^\d{1,9}$/.test(v.trim()) ? Number(v) : null);

  async function save(id: string) {
    const a = num(imp), b = num(clk), c = num(eng);
    if (a === null || b === null || c === null) return setErr('Type whole numbers in all three boxes.');
    setBusy(true); setErr('');
    try { await recordPerformance(id, 'in_app', a, b, c); setOpen(null); setImp(''); setClk(''); setEng(''); await list.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  return (
    <MediaScreen loading={list.loading} error={list.error || perms.error} onRetry={() => void list.reload()} denied={perms.data && !has(p, 'media.performance') ? 'You do not have access to performance numbers.' : undefined}>
      <Text style={s.title}>Performance</Text>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {(list.data ?? []).map((r) => (
        <React.Fragment key={r.content_id}>
          <Card title={r.title} note={`${r.impressions} views · ${r.clicks} clicks · ${r.engagements} engagements`} onPress={has(p, 'media.performance') ? () => setOpen(open === r.content_id ? null : r.content_id) : undefined} />
          {open === r.content_id ? (
            <>
              <Field label="Views" value={imp} onChangeText={setImp} keyboardType="number-pad" />
              <Field label="Clicks" value={clk} onChangeText={setClk} keyboardType="number-pad" />
              <Field label="Engagements" value={eng} onChangeText={setEng} keyboardType="number-pad" />
              <Button title="Add these numbers" loading={busy} onPress={() => void save(r.content_id)} />
            </>
          ) : null}
        </React.Fragment>
      ))}
      {list.data && list.data.length === 0 ? <Text style={s.muted}>Numbers appear once content is published.</Text> : null}
    </MediaScreen>
  );
}
import React from 'react';
