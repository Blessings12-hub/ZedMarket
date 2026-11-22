-- ZedMarket database, part 6: reference data and starter settings.
-- Safe to run more than once.

-- Launch categories from section 2 of the blueprint. Appliances, vehicles,
-- property, groceries, hardware and services stay out until moderation,
-- category rules and operational support are ready for them.
insert into public.categories (slug, name, sort_order) values
  ('electronics', 'Electronics', 1),
  ('fashion', 'Fashion', 2),
  ('furniture', 'Furniture', 3),
  ('household-goods', 'Household goods', 4)
on conflict (slug) do nothing;

-- Lusaka first. The blueprint recommends a concentrated launch before going national.
-- Starter list of areas; check it against how people in Lusaka actually describe where they are.
insert into public.locations (province, town, area) values
  ('Lusaka', 'Lusaka', null),
  ('Lusaka', 'Lusaka', 'Lusaka CBD'),
  ('Lusaka', 'Lusaka', 'Kabulonga'),
  ('Lusaka', 'Lusaka', 'Woodlands'),
  ('Lusaka', 'Lusaka', 'Chilenje'),
  ('Lusaka', 'Lusaka', 'Roma'),
  ('Lusaka', 'Lusaka', 'Matero'),
  ('Lusaka', 'Lusaka', 'Northmead'),
  ('Lusaka', 'Lusaka', 'Rhodes Park'),
  ('Lusaka', 'Lusaka', 'Olympia Park'),
  ('Lusaka', 'Lusaka', 'Kabwata'),
  ('Lusaka', 'Lusaka', 'Chelston'),
  ('Lusaka', 'Lusaka', 'Makeni'),
  ('Lusaka', 'Lusaka', 'Chawama'),
  ('Lusaka', 'Lusaka', 'Kalingalinga'),
  ('Lusaka', 'Lusaka', 'Avondale'),
  ('Lusaka', 'Lusaka', 'Sunningdale'),
  ('Lusaka', 'Lusaka', 'Ibex Hill'),
  ('Lusaka', 'Lusaka', 'Libala'),
  ('Lusaka', 'Lusaka', 'Emmasdale'),
  ('Lusaka', 'Lusaka', 'Mandevu'),
  ('Lusaka', 'Lusaka', 'Chaisa'),
  ('Lusaka', 'Lusaka', 'Chazanga'),
  ('Lusaka', 'Lusaka', 'Kabanana'),
  ('Lusaka', 'Lusaka', 'Chunga'),
  ('Lusaka', 'Lusaka', 'Garden'),
  ('Lusaka', 'Lusaka', 'Lilanda'),
  ('Lusaka', 'Lusaka', 'Ng''ombe'),
  ('Lusaka', 'Lusaka', 'George'),
  ('Lusaka', 'Lusaka', 'Chudleigh'),
  ('Lusaka', 'Lusaka', 'Kalundu'),
  ('Lusaka', 'Lusaka', 'Chamba Valley'),
  ('Lusaka', 'Lusaka', 'Chainama'),
  ('Lusaka', 'Lusaka', 'Kamanga'),
  ('Lusaka', 'Lusaka', 'Chainda'),
  ('Lusaka', 'Lusaka', 'Mutendere'),
  ('Lusaka', 'Lusaka', 'Bauleni'),
  ('Lusaka', 'Lusaka', 'PHI'),
  ('Lusaka', 'Lusaka', 'Foxdale'),
  ('Lusaka', 'Lusaka', 'Chalala'),
  ('Lusaka', 'Lusaka', 'New Kasama'),
  ('Lusaka', 'Lusaka', 'Leopards Hill'),
  ('Lusaka', 'Lusaka', 'Lilayi'),
  ('Lusaka', 'Lusaka', 'Ridgeway'),
  ('Lusaka', 'Lusaka', 'Nyumba Yanga'),
  ('Lusaka', 'Lusaka', 'Kamwala'),
  ('Lusaka', 'Lusaka', 'Kamwala South'),
  ('Lusaka', 'Lusaka', 'Chilenje South'),
  ('Lusaka', 'Lusaka', 'John Howard'),
  ('Lusaka', 'Lusaka', 'Kanyama'),
  ('Lusaka', 'Lusaka', 'John Laing'),
  ('Lusaka', 'Lusaka', 'Misisi'),
  ('Lusaka', 'Lusaka', 'Chibolya'),
  ('Lusaka', 'Lusaka', 'Chipata Compound'),
  ('Lusaka', 'Lusaka', 'Chinika'),
  ('Lusaka', 'Lusaka', 'Industrial Area'),
  ('Lusaka', 'Lusaka', 'Longacres'),
  ('Lusaka', 'Lusaka', 'Fairview'),
  ('Lusaka', 'Lusaka', 'Cathedral Hill'),
  ('Lusaka', 'Lusaka', 'Mass Media'),
  ('Lusaka', 'Lusaka', 'Thorn Park')
on conflict do nothing;

-- Every value below is a starting point, not a decision. Tune them after the pilot.
insert into public.platform_settings (key, value, note) values
  ('moderation.high_value_zmw', '10000', 'A new seller listing at or above this price goes to the moderation queue.'),
  ('moderation.new_seller_days', '30', 'How long an account counts as new for the high value rule.'),
  ('moderation.repeat_report_threshold', '3', 'Distinct reporters on one target before a risk flag is raised.'),
  ('listing.require_contact_verification', 'false', 'Turn on once phone verification (an SMS provider) is set up.'),
  ('rate_limit.listing.max', '20', 'Listings per window. Starter value.'),
  ('rate_limit.listing.window_minutes', '1440', null),
  ('rate_limit.message.max', '60', 'Messages per window. Starter value.'),
  ('rate_limit.message.window_minutes', '10', null),
  ('rate_limit.report.max', '20', 'Reports per window. Starter value.'),
  ('rate_limit.report.window_minutes', '1440', null),
  ('rate_limit.conversation.max', '30', 'New conversations per window. Starter value.'),
  ('rate_limit.conversation.window_minutes', '1440', null),
  ('retention.identity_documents_days', '30', 'Days to keep an identity document after review. Needs a decision with legal advice.'),
  ('retention.delivery_locations_days', '7', 'Days to keep location points after a delivery. Needs a decision with legal advice.')
on conflict (key) do nothing;

-- Starter terms. They send a listing to a person for review; none of them block anything yet.
insert into public.prohibited_terms (term, action) values
  ('firearm', 'flag'),
  ('ammunition', 'flag'),
  ('counterfeit', 'flag'),
  ('stolen', 'flag'),
  ('fake id', 'flag'),
  ('replica', 'flag')
on conflict (term) do nothing;
