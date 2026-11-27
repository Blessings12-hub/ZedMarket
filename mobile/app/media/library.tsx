import { useState } from 'react';
import { Image, Text, View } from 'react-native';

import { useAuth } from '../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../src/components/ui';
import { archiveAsset, assetUrl, deleteAsset, fetchPermissions, listAssets, updateAsset, uploadAsset, type Asset } from '../../src/features/media/api';
import { CATEGORIES, deleteConfirmed, formatBytes, has, scanLabel } from '../../src/features/media/domain';
import { Card, MediaScreen, styles as s, when } from '../../src/features/media/ui';
import { useLoad } from '../../src/features/media/useLoad';
import { friendlyError } from '../../src/lib/errors';

export default function Library() {
  const { userId } = useAuth();
  const perms = useLoad(fetchPermissions);
  const [view, setView] = useState<'active' | 'archived'>('active');
  const list = useLoad(() => listAssets(view), [view]);
  const [open, setOpen] = useState<Asset | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [title, setTitle] = useState('');
  const [desc, setDesc] = useState('');
  const [category, setCategory] = useState('other');
  const [typed, setTyped] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const p = perms.data ?? [];

  async function run(fn: () => Promise<unknown>, ok: string, after?: () => void) {
    setBusy(true); setErr(''); setMsg('');
    try { await fn(); setMsg(ok); after?.(); await list.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  async function select(a: Asset) {
    setOpen(a); setTitle(a.title); setDesc(a.description ?? ''); setCategory(a.category); setTyped(''); setPreview(null); setErr(''); setMsg('');
    if (a.kind === 'image') setPreview(await assetUrl(a.storagePath));
  }

  return (
    <MediaScreen loading={list.loading} error={list.error || perms.error} onRetry={() => { void list.reload(); void perms.reload(); }} denied={perms.data && !has(p, 'media.access') ? 'You do not have access to the Media Library.' : undefined}>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {msg ? <Notice>{msg}</Notice> : null}

      {!open ? (
        <>
          <View style={s.row}>
            <Chip label="Active" selected={view === 'active'} onPress={() => setView('active')} />
            <Chip label="Archived" selected={view === 'archived'} onPress={() => setView('archived')} />
          </View>
          {has(p, 'media.upload') && view === 'active' ? (
            <View style={{ gap: 8 }}>
              <SectionTitle>Upload a file</SectionTitle>
              <Field label="Title" value={title} onChangeText={setTitle} maxLength={120} />
              <View style={s.row}>
                {CATEGORIES.map((c) => <Chip key={c.key} label={c.label} selected={category === c.key} onPress={() => setCategory(c.key)} />)}
              </View>
              <Button title="Choose a file and upload" loading={busy} disabled={title.trim().length < 2 || !userId}
                onPress={() => void run(() => uploadAsset(userId!, { title: title.trim(), description: '', category }), 'Uploaded. It will be usable once the safety check passes.', () => setTitle(''))} />
              <Text style={s.meta}>Images up to 10 MB and videos up to 50 MB. Files are checked before they can be published.</Text>
            </View>
          ) : null}
          {(list.data ?? []).map((a) => (
            <Card key={a.id} title={a.title} note={`${a.kind} · ${formatBytes(a.sizeBytes)} · ${scanLabel(a.scanStatus)}`} meta={`${a.uploaderName} · ${when(a.createdAt)}`} right={`v${a.version}`} onPress={() => void select(a)} />
          ))}
          {list.data && list.data.length === 0 ? <Text style={s.muted}>Nothing here yet.</Text> : null}
        </>
      ) : (
        <>
          <Button title="Back to the library" variant="secondary" onPress={() => setOpen(null)} />
          {preview ? <Image source={{ uri: preview }} style={{ width: '100%', height: 220, borderRadius: 8 }} resizeMode="contain" /> : null}
          <Text style={s.muted}>{`${open.kind} · ${formatBytes(open.sizeBytes)} · ${scanLabel(open.scanStatus)} · uploaded by ${open.uploaderName}`}</Text>
          {has(p, 'media.upload') ? (
            <>
              <Field label="Title" value={title} onChangeText={setTitle} maxLength={120} />
              <Field label="Description" value={desc} onChangeText={setDesc} multiline maxLength={500} />
              <View style={s.row}>{CATEGORIES.map((c) => <Chip key={c.key} label={c.label} selected={category === c.key} onPress={() => setCategory(c.key)} />)}</View>
              <Button title="Save changes" loading={busy} onPress={() => void run(() => updateAsset(open.id, title.trim(), desc, category), 'Saved. The old version is kept in the history.')} />
            </>
          ) : null}
          {has(p, 'media.archive') ? (
            <Button title={open.status === 'archived' ? 'Restore' : 'Archive'} variant="secondary" loading={busy}
              onPress={() => void run(() => archiveAsset(open.id, open.status !== 'archived'), open.status === 'archived' ? 'Restored.' : 'Archived.', () => setOpen(null))} />
          ) : null}
          {has(p, 'media.delete') && open.status === 'archived' ? (
            <View style={{ gap: 8 }}>
              <SectionTitle>Delete permanently</SectionTitle>
              <Text style={s.muted}>This cannot be undone. Files used by published or scheduled content cannot be deleted. Type DELETE to confirm.</Text>
              <Field label="Type DELETE" value={typed} onChangeText={setTyped} autoCapitalize="characters" />
              <Button title="Delete permanently" variant="danger" loading={busy} disabled={!deleteConfirmed(typed)}
                onPress={() => void run(() => deleteAsset(open.id, typed.trim()), 'Deleted.', () => setOpen(null))} />
            </View>
          ) : null}
        </>
      )}
    </MediaScreen>
  );
}
