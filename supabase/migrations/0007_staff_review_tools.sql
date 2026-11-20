-- Two staff actions the admin screens need that did not exist yet:
-- marking a risk flag as looked at, and hiding a review that breaks the rules.

create function public.mark_risk_flag_reviewed(p_flag_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.risk_flags set status = 'reviewed' where id = p_flag_id and status = 'open';
  if not found then
    raise exception 'No open flag with that id.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('risk_flag.reviewed', 'risk_flag', p_flag_id::text, '{}'::jsonb);
end;
$$;

create function public.set_review_hidden(p_review_id uuid, p_hidden boolean, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reason is required.' using errcode = 'check_violation';
  end if;

  update public.reviews set is_hidden = p_hidden where id = p_review_id;
  if not found then
    raise exception 'Review not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('review.visibility_changed', 'review', p_review_id::text,
    jsonb_build_object('hidden', p_hidden, 'reason', p_reason));
end;
$$;

grant execute on function
  public.mark_risk_flag_reviewed(uuid),
  public.set_review_hidden(uuid, boolean, text)
to authenticated;
