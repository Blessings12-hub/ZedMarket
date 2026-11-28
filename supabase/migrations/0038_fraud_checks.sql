-- 0038: automatic fraud checks. They only RAISE FLAGS for a moderator to look at (risk_flags, shown in Staff, Risk flags).
-- Nothing is hidden, removed or blocked by these checks, because a computer guess must never punish a real seller.
--
--   repeated_listing_text   the same seller posted the same words several times in a week
--   copied_listing_text     different sellers posted the same words (a common sign of copied scam ads)
--   price_far_below         much cheaper than similar items (too good to be true)
--   price_far_above         much dearer than similar items
--   listing_churn           a seller keeps posting items and deleting them within a day
--
-- The numbers below are STARTING VALUES in platform_settings. Tune them with real data from the pilot.

insert into public.platform_settings (key, value, note) values
  ('fraud.repeat_text_threshold', '3', 'How many identical listings (same seller, last 7 days) raise a repeated-text flag. Starter value.'),
  ('fraud.copied_text_sellers', '3', 'How many different sellers with identical listing words (last 14 days) raise a copied-text flag. Starter value.'),
  ('fraud.price_min_samples', '8', 'How many similar active listings are needed before prices are compared. Starter value.'),
  ('fraud.price_low_ratio', '0.2', 'A price below this share of the category median raises a flag. Starter value.'),
  ('fraud.price_high_ratio', '5', 'A price above this many times the category median raises a flag. Starter value.'),
  ('fraud.churn_threshold', '5', 'How many listings removed within a day of posting (last 7 days) raise a churn flag. Starter value.')
on conflict (key) do nothing;

-- A fingerprint of the words: lower case, extra spaces and punctuation ignored.
alter table public.listings add column text_fingerprint text;
create index listings_text_fingerprint_idx on public.listings (text_fingerprint) where text_fingerprint is not null;
create index listings_seller_created_idx on public.listings (seller_id, created_at desc);

create function public.listing_text_fingerprint(p_title text, p_description text) returns text
language sql immutable set search_path = ''
as $$
  select case
    when char_length(regexp_replace(lower(coalesce(p_title, '') || ' ' || coalesce(p_description, '')), '[^a-z0-9]+', '', 'g')) < 20 then null
    else md5(regexp_replace(lower(coalesce(p_title, '') || ' ' || coalesce(p_description, '')), '[^a-z0-9]+', '', 'g'))
  end
$$;

create function public.listings_set_fingerprint() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.text_fingerprint := public.listing_text_fingerprint(new.title, new.description);
  return new;
end;
$$;
create trigger listings_fingerprint before insert or update of title, description on public.listings
  for each row execute function public.listings_set_fingerprint();

-- Fill the fingerprint for listings that already exist.
update public.listings set text_fingerprint = public.listing_text_fingerprint(title, description) where text_fingerprint is null;

-- Adds a flag unless an open one with the same signal already exists for that subject.
create function public.raise_risk_flag(p_type text, p_subject uuid, p_signal text, p_detail jsonb) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.risk_flags f where f.subject_id = p_subject and f.signal = p_signal and f.status = 'open') then
    return;
  end if;
  insert into public.risk_flags (subject_type, subject_id, signal, detail) values (p_type, p_subject, p_signal, p_detail);
end;
$$;

create function public.listings_fraud_after_write() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  same_seller integer;
  other_sellers integer;
  n integer;
  med numeric;
  low numeric := public.setting_numeric('fraud.price_low_ratio', 0.2);
  high numeric := public.setting_numeric('fraud.price_high_ratio', 5);
begin
  if new.status = 'removed' or new.moderation_status = 'rejected' then
    return new;
  end if;

  if tg_op = 'INSERT' or new.text_fingerprint is distinct from old.text_fingerprint then
    if new.text_fingerprint is not null then
      select count(*) into same_seller from public.listings l
       where l.seller_id = new.seller_id and l.text_fingerprint = new.text_fingerprint
         and l.status <> 'removed' and l.created_at > now() - interval '7 days';
      if same_seller >= public.setting_numeric('fraud.repeat_text_threshold', 3) then
        perform public.raise_risk_flag('user', new.seller_id, 'repeated_listing_text', jsonb_build_object('copies', same_seller));
      end if;

      select count(distinct l.seller_id) into other_sellers from public.listings l
       where l.text_fingerprint = new.text_fingerprint and l.status <> 'removed' and l.created_at > now() - interval '14 days';
      if other_sellers >= public.setting_numeric('fraud.copied_text_sellers', 3) then
        perform public.raise_risk_flag('listing', new.id, 'copied_listing_text', jsonb_build_object('sellers', other_sellers));
      end if;
    end if;
  end if;

  if tg_op = 'INSERT' or new.price_zmw is distinct from old.price_zmw or new.category_id is distinct from old.category_id then
    select count(*), percentile_cont(0.5) within group (order by l.price_zmw) into n, med
      from public.listings l
     where l.category_id = new.category_id and l.status = 'active' and l.moderation_status = 'approved'
       and l.id <> new.id and l.price_zmw > 0;
    if n >= public.setting_numeric('fraud.price_min_samples', 8) and med > 0 then
      if new.price_zmw < med * low then
        perform public.raise_risk_flag('listing', new.id, 'price_far_below', jsonb_build_object('price', new.price_zmw, 'median', round(med, 2), 'similar', n));
      elsif new.price_zmw > med * high then
        perform public.raise_risk_flag('listing', new.id, 'price_far_above', jsonb_build_object('price', new.price_zmw, 'median', round(med, 2), 'similar', n));
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger listings_fraud after insert or update of title, description, price_zmw, category_id on public.listings
  for each row execute function public.listings_fraud_after_write();

-- Posting and deleting again and again: the seller removed their own listings within a day of posting them.
-- Removals by staff or by closing an account carry a moderation note and are not counted.
create function public.listings_churn_after_update() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  if new.status = 'removed' and old.status <> 'removed' and new.moderation_note is null then
    select count(*) into n from public.listings l
     where l.seller_id = new.seller_id and l.status = 'removed' and l.moderation_note is null
       and l.created_at > now() - interval '7 days' and l.updated_at - l.created_at < interval '1 day';
    if n >= public.setting_numeric('fraud.churn_threshold', 5) then
      perform public.raise_risk_flag('user', new.seller_id, 'listing_churn', jsonb_build_object('removed_within_a_day', n));
    end if;
  end if;
  return new;
end;
$$;
create trigger listings_churn after update of status on public.listings
  for each row execute function public.listings_churn_after_update();

revoke execute on function public.raise_risk_flag(text, uuid, text, jsonb), public.listings_fraud_after_write(),
  public.listings_churn_after_update() from public, anon, authenticated;
