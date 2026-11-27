import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import { useAuth } from '../../../src/auth/AuthProvider';
import { Button, Chip, Field, Notice, SectionTitle } from '../../../src/components/ui';
import { fetchPermissions, getContent, listCampaigns, publishContent, reviewContent, saveContent, submitContent, withdrawContent, type ContentDetail } from '../../../src/features/media/api';
import { ACTION_LABEL, CHANNELS, CONTENT_KINDS, NEEDS_NOTE, STATUS_LABEL, contentActions, contentProblem, has, type ContentAction } from '../../../src/features/media/domain';
import { MediaScreen, styles as s, when } from '../../../src/features/media/ui';
import { useLoad } from '../../../src/features/media/useLoad';
import { friendlyError } from '../../../src/lib/errors';

export default function Item() {
  const router = useRouter();
  const { userId } = useAuth();
  const { id, kind: kindParam } = useLocalSearchParams<{ id: string; kind?: string }>();
  const isNew = id === 'new';
  const perms = useLoad(fetchPermissions);
  const detail = useLoad<ContentDetail | null>(async () => (isNew ? null : getContent(id)), [id]);
  const campaigns = useLoad(listCampaigns);
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [kind, setKind] = useState(kindParam ?? 'poster');
  const [channel, setChannel] = useState<string | null>('in_app');
  const [campaignId, setCampaignId] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [when_, setWhen] = useState('');
  const [pending, setPending] = useState<ContentAction | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const c = detail.data?.content;
  const p = perms.data ?? [];

  useEffect(() => {
    if (c) { setTitle(c.title); setBody(c.body ?? ''); setKind(c.kind); setChannel(c.channel); setCampaignId(c.campaignId); }
  }, [c?.id, c?.version]); // eslint-disable-line react-hooks/exhaustive-deps

  const isCreator = isNew || c?.createdBy === userId;
  const actions = c ? contentActions(c.status, p, isCreator) : [];
  const canEdit = isNew ? has(p, 'media.create') : actions.includes('edit');

  async function guard(fn: () => Promise<unknown>, ok: string) {
    setBusy(true); setErr(''); setMsg('');
    try { await fn(); setMsg(ok); setPending(null); setNote(''); await detail.reload(); } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  async function save() {
    const problem = contentProblem(title, body);
    if (problem) return setErr(problem);
    setBusy(true); setErr('');
    try {
      const newId = await saveContent({ id: isNew ? null : id, kind, title: title.trim(), body, channel, campaignId, assetIds: detail.data?.assetIds ?? [] });
      if (isNew) router.replace(`/media/item/${newId}` as never); else { setMsg('Saved. The earlier version is kept.'); await detail.reload(); }
    } catch (e) { setErr(friendlyError(e)); } finally { setBusy(false); }
  }
  function run(a: ContentAction) {
    if (!c || a === 'edit') return;
    if (NEEDS_NOTE.includes(a) || a === 'schedule') return setPending(a);
    if (a === 'submit') return void guard(() => submitContent(c.id), 'Sent for approval.');
    if (a === 'approve') return void guard(() => reviewContent(c.id, 'approve', ''), 'Approved.');
    if (a === 'publish') return void guard(() => publishContent(c.id, null), 'Published.');
  }
  function confirmPending() {
    if (!c || !pending) return;
    if (pending === 'schedule') {
      const at = new Date(`${when_.trim().replace(' ', 'T')}+02:00`);
      if (Number.isNaN(at.getTime()) || at.getTime() < Date.now()) return setErr('Type a future date and time like 2026-12-01 09:00 (Lusaka time).');
      return void guard(() => publishContent(c.id, at.toISOString()), 'Scheduled.');
    }
    if (note.trim().length < 3) return setErr('Please write a short reason.');
    if (pending === 'changes') return void guard(() => reviewContent(c.id, 'changes', note.trim()), 'Changes requested.');
    if (pending === 'reject') return void guard(() => reviewContent(c.id, 'reject', note.trim()), 'Rejected.');
    if (pending === 'withdraw') return void guard(() => withdrawContent(c.id, note.trim()), 'Withdrawn.');
  }

  return (
    <MediaScreen loading={detail.loading} error={detail.error || perms.error} onRetry={() => void detail.reload()} denied={perms.data && !has(p, 'media.access') ? 'You do not have access to the Content Studio.' : undefined}>
      {err ? <Notice tone="error">{err}</Notice> : null}
      {msg ? <Notice>{msg}</Notice> : null}
      <Text style={s.title}>{c ? STATUS_LABEL[c.status] : 'New content'}</Text>
      {c ? <Text style={s.muted}>{`By ${c.creatorName} · created ${when(c.createdAt)}${c.reviewerName ? ` · reviewed by ${c.reviewerName} ${when(c.reviewedAt)}` : ''}${c.publishedAt ? ` · published ${when(c.publishedAt)}` : ''}`}</Text> : null}
      {c?.reviewNote ? <Notice tone="warning">{`Reviewer note: ${c.reviewNote}`}</Notice> : null}

      {canEdit ? (
        <>
          <View style={s.row}>{CONTENT_KINDS.map((k) => <Chip key={k.key} label={k.label} selected={kind === k.key} onPress={() => setKind(k.key)} />)}</View>
          <Field label="Title" value={title} onChangeText={setTitle} maxLength={120} required />
          <Field label="Text" value={body} onChangeText={setBody} multiline maxLength={5000} style={{ minHeight: 120 }} />
          <SectionTitle>Where it will appear</SectionTitle>
          <View style={s.row}>{CHANNELS.map((k) => <Chip key={k.key} label={k.label} selected={channel === k.key} onPress={() => setChannel(k.key)} />)}</View>
          {(campaigns.data ?? []).length > 0 ? (
            <>
              <SectionTitle>Campaign (optional)</SectionTitle>
              <View style={s.row}>
                <Chip label="None" selected={!campaignId} onPress={() => setCampaignId(null)} />
                {(campaigns.data ?? []).map((k) => <Chip key={k.id} label={k.name} selected={campaignId === k.id} onPress={() => setCampaignId(k.id)} />)}
              </View>
            </>
          ) : null}
          <Button title={isNew ? 'Save draft' : 'Save changes'} loading={busy} onPress={() => void save()} />
        </>
      ) : c ? (
        <>
          <Text style={s.cardTitle}>{c.title}</Text>
          <Text style={s.muted}>{c.body ?? ''}</Text>
        </>
      ) : null}

      {actions.filter((a) => a !== 'edit').map((a) => (
        <Button key={a} title={ACTION_LABEL[a]} variant={a === 'reject' || a === 'withdraw' ? 'danger' : a === 'approve' || a === 'publish' || a === 'submit' ? 'primary' : 'secondary'} loading={busy} onPress={() => run(a)} />
      ))}

      {pending ? (
        <View style={{ gap: 8 }}>
          <SectionTitle>{ACTION_LABEL[pending]}</SectionTitle>
          {pending === 'schedule' ? <Field label="Date and time (Lusaka), e.g. 2026-12-01 09:00" value={when_} onChangeText={setWhen} /> : <Field label="Reason" value={note} onChangeText={setNote} multiline maxLength={500} />}
          <Button title="Confirm" loading={busy} onPress={confirmPending} />
          <Button title="Cancel" variant="secondary" onPress={() => { setPending(null); setErr(''); }} />
        </View>
      ) : null}

      {detail.data ? (
        <>
          <SectionTitle>History</SectionTitle>
          {detail.data.events.map((e) => <Text key={e.id} style={s.muted}>{`${when(e.at)} · ${e.actor} · ${e.event.replace(/_/g, ' ')}${e.note ? ` — ${e.note}` : ''}`}</Text>)}
          <SectionTitle>Versions</SectionTitle>
          {detail.data.versions.map((v) => <Text key={v.version} style={s.muted}>{`Version ${v.version} · ${v.title} · ${when(v.at)}`}</Text>)}
        </>
      ) : null}
    </MediaScreen>
  );
}
