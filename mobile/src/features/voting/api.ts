import type { ProposalStatus, VoteChoice, VoteSection } from '../../domain/voting';
import { supabase } from '../../lib/supabase';

// Every call goes through a database function (migration 0015). The voting tables are closed to the app, so
// there is nothing else to call, and the database decides who may see and do what.

export type Proposal = {
  id: string;
  reference: string;
  title: string;
  description: string;
  reason: string;
  status: ProposalStatus;
  confidential: boolean;
  proposerId: string;
  proposerName: string;
  createdAt: string;
  opensAt: string | null;
  closesAt: string | null;
  openedAt: string | null;
  closedAt: string | null;
  eligibleCount: number | null;
  requiredVotes: number | null;
  forCount: number | null;
  againstCount: number | null;
  abstainCount: number | null;
  countsHidden: boolean;
  outcome: string | null;
  myChoice: VoteChoice | null;
  iAmProposer: boolean;
  canVote: boolean;
  resubmittedFrom: string | null;
  resubmittedAs: string | null;
  cancelReason: string | null;
  votedCount: number | null;
};

export type VoteAccess = { isStaff: boolean; canPropose: boolean; canAudit: boolean };
export type MyVote = { proposalId: string; reference: string; title: string; confidential: boolean; myChoice: VoteChoice; castAt: string; status: ProposalStatus };
export type Ballot = { voterId: string; voterName: string; choice: VoteChoice; castAt: string };
export type AuditRow = { seq: number; actorName: string | null; action: string; details: Record<string, unknown>; createdAt: string; rowHash: string };

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

function toProposal(r: any): Proposal {
  return {
    id: r.id, reference: r.reference, title: r.title, description: r.description, reason: r.reason,
    status: r.status, confidential: r.confidential, proposerId: r.proposer_id, proposerName: r.proposer_name,
    createdAt: r.created_at, opensAt: r.opens_at, closesAt: r.closes_at, openedAt: r.opened_at, closedAt: r.closed_at,
    eligibleCount: r.eligible_count, requiredVotes: r.required_votes,
    forCount: r.for_count, againstCount: r.against_count, abstainCount: r.abstain_count,
    countsHidden: !!r.counts_hidden, outcome: r.outcome, myChoice: r.my_choice, iAmProposer: !!r.i_am_proposer,
    canVote: !!r.can_vote, resubmittedFrom: r.resubmitted_from, resubmittedAs: r.resubmitted_as,
    cancelReason: r.cancel_reason, votedCount: r.voted_count,
  };
}

export async function fetchVoteAccess(): Promise<VoteAccess> {
  const rows = await rpc<any[]>('my_staff_vote_access');
  const r = rows?.[0];
  return { isStaff: !!r?.is_staff, canPropose: !!r?.can_propose, canAudit: !!r?.can_audit };
}

export async function fetchProposals(section: VoteSection): Promise<Proposal[]> {
  return (await rpc<any[]>('list_staff_proposals', { p_section: section })).map(toProposal);
}

export async function fetchProposal(id: string): Promise<Proposal | null> {
  const rows = await rpc<any[]>('get_staff_proposal', { p_id: id });
  return rows.length ? toProposal(rows[0]) : null;
}

export async function fetchMyVotes(): Promise<MyVote[]> {
  return (await rpc<any[]>('my_staff_votes')).map((r) => ({
    proposalId: r.proposal_id, reference: r.reference, title: r.title, confidential: r.confidential,
    myChoice: r.my_choice, castAt: r.cast_at, status: r.status,
  }));
}

export async function createProposal(input: { title: string; description: string; reason: string; confidential: boolean }): Promise<string> {
  return rpc<string>('create_staff_proposal', {
    p_title: input.title, p_description: input.description, p_reason: input.reason,
    p_confidential: input.confidential, p_no_override_confirmed: true,
  });
}

export async function updateProposal(id: string, input: { title: string; description: string; reason: string; confidential: boolean }): Promise<void> {
  await rpc('update_staff_proposal', {
    p_id: id, p_title: input.title, p_description: input.description, p_reason: input.reason, p_confidential: input.confidential,
  });
}

// With no start time the vote opens straight away. Returns 'active' or 'pending'.
export async function submitProposal(id: string, opensAt: string | null, closesAt: string): Promise<string> {
  return rpc<string>('submit_staff_proposal', { p_id: id, p_opens_at: opensAt, p_closes_at: closesAt });
}

export async function cancelProposal(id: string, reason: string): Promise<void> {
  await rpc('cancel_staff_proposal', { p_id: id, p_reason: reason });
}

export async function resubmitProposal(id: string): Promise<string> {
  return rpc<string>('resubmit_staff_proposal', { p_id: id });
}

// Returns the proposal status afterwards: 'active' while open, or the final result if this vote decided it.
export async function castVote(id: string, choice: VoteChoice): Promise<string> {
  return rpc<string>('cast_staff_vote', { p_id: id, p_choice: choice });
}

export async function fetchBallots(id: string): Promise<Ballot[]> {
  return (await rpc<any[]>('staff_vote_ballots', { p_id: id })).map((r) => ({
    voterId: r.voter_id, voterName: r.voter_name, choice: r.choice, castAt: r.cast_at,
  }));
}

export async function fetchAudit(id: string): Promise<{ rows: AuditRow[]; intact: boolean }> {
  const [rows, intact] = await Promise.all([rpc<any[]>('staff_vote_audit', { p_id: id }), rpc<boolean>('verify_staff_vote_audit', { p_id: id })]);
  return {
    intact: !!intact,
    rows: rows.map((r) => ({ seq: r.seq, actorName: r.actor_name, action: r.action, details: r.details ?? {}, createdAt: r.created_at, rowHash: r.row_hash })),
  };
}
